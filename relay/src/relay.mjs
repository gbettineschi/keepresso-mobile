import {createHash,createHmac,timingSafeEqual,randomUUID} from 'node:crypto';
export class RelayError extends Error { constructor(status,code){super(code);this.status=status;this.code=code;} }
const fail=(status,code)=>{throw new RelayError(status,code);};
export const hash=s=>createHash('sha256').update(s).digest('hex');
const equal=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.length===b.length&&timingSafeEqual(Buffer.from(a),Buffer.from(b));
const uuid=s=>typeof s==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s);
const object=o=>o!==null&&typeof o==='object'&&!Array.isArray(o);
const fields=(o,allowed)=>{if(!object(o)||Object.keys(o).some(k=>!allowed.includes(k)))fail(400,'invalid_fields');};
const b64=(s,size)=>{if(typeof s!=='string'||s.length>90000||!s.length||s.length%4!==0||!/^[A-Za-z0-9+/]*={0,2}$/.test(s))fail(400,'invalid_encoding');const b=Buffer.from(s,'base64');if(b.toString('base64')!==s||(size!==undefined&&b.length!==size))fail(400,'invalid_encoding');return b;};
const fingerprint=e=>hash(JSON.stringify(Object.fromEntries(Object.entries(e).sort(([a],[b])=>a.localeCompare(b)))));
export function validateEnvelope(e,{macId,deviceId,direction,kind,epoch,now}){
  fields(e,['version','macId','deviceId','id','epoch','direction','kind','createdAt','expiresAt','nonce','ciphertext']);
  if(e.version!==1||!uuid(e.macId)||!uuid(e.deviceId)||!uuid(e.id)||!uuid(e.epoch)||e.macId!==macId||(deviceId&&e.deviceId!==deviceId)||e.direction!==direction||e.kind!==kind||(epoch&&e.epoch!==epoch))fail(400,'invalid_envelope');
  const max={command:30,response:120,state:15,event:300}[kind];
  if(!Number.isSafeInteger(e.createdAt)||!Number.isSafeInteger(e.expiresAt)||e.expiresAt<=e.createdAt||e.expiresAt-e.createdAt>max||e.createdAt>now+10||e.expiresAt<=now)fail(400,'expired_or_invalid_time');
  b64(e.nonce,12);if(b64(e.ciphertext).length<16||Buffer.byteLength(JSON.stringify(e))>65536)fail(400,'invalid_envelope_size');return e;
}
const ops={enroll:['deviceId','tokenHash'],revoke:['deviceId'],sync:['epoch','states','responses','events'],poll:['deviceId','after'],send:['deviceId','envelope'],push:['deviceId','token']};
export class Relay {
  constructor({store,macId,macTokenHash,now=()=>Math.floor(Date.now()/1000),push}){
    if(!uuid(macId)||!/^[0-9a-f]{64}$/.test(macTokenHash))throw new Error('Invalid relay configuration');
    Object.assign(this,{store,macId,macTokenHash,now,push});
  }
  async handle(authorization,body){
    try{
      if(!object(body)||!ops[body.op])fail(400,'invalid_operation');
      fields(body,['op','macId',...ops[body.op]]);
      if(body.macId!==this.macId)fail(401,'unauthorized');
      if(typeof authorization!=='string'||!authorization.startsWith('Bearer ')||authorization.length>256)fail(401,'unauthorized');
      const bearer=authorization.slice(7);const isMac=equal(hash(bearer),this.macTokenHash);
      const pieces=bearer.split('.');const tokenHash=hash(pieces[0]);
      if(['enroll','revoke','sync'].includes(body.op)&&!isMac)fail(401,'unauthorized');
      if(!['enroll','revoke','sync'].includes(body.op)&&isMac)fail(401,'unauthorized');
      if(body.op!=='sync'&&!uuid(body.deviceId))fail(400,'invalid_device');
      if(!isMac){
        const expected=createHmac('sha256',this.macTokenHash).update(`keepresso-mobile/relay/v1/access-ticket\n${this.macId}\n${body.deviceId}\n${tokenHash}`).digest('base64');
        if(pieces.length!==2||!equal(pieces[1],expected))fail(401,'unauthorized');
      }
      const now=this.now();let pendingPush=[];
      const result=await this.store.transaction(async tx=>{
        pendingPush=[]; // A Firestore transaction may re-run before commit.
        const base=`macs/${this.macId}`,devices=`${base}/devices`,commands=`${base}/commands`,indexPath=`${base}/private/active-devices`;
        const devicePath=id=>`${devices}/${id}`,messagePath=(id,msg)=>`${devicePath(id)}/messages/${msg}`;
        const active=async id=>{const d=await tx.get(devicePath(id));if(!d||d.revoked)fail(403,'device_not_enrolled');return d;};
        let device;
        if(!isMac){device=await tx.get(devicePath(body.deviceId));if(!device||device.revoked||!equal(tokenHash,device.tokenHash))fail(401,'unauthorized');}
        if(body.op==='enroll'){
          if(typeof body.tokenHash!=='string'||!/^[0-9a-f]{64}$/.test(body.tokenHash))fail(400,'invalid_token_hash');
          const index=await tx.get(indexPath)??{ids:[]};const old=await tx.get(devicePath(body.deviceId));
          if(!index.ids.includes(body.deviceId)&&index.ids.length>=8)fail(429,'device_limit');
          const unchanged=old&&!old.revoked&&old.tokenHash===body.tokenHash;
          tx.set(devicePath(body.deviceId),unchanged?old:{tokenHash:body.tokenHash,revoked:false,state:null,pushToken:null,after:0});
          if(!index.ids.includes(body.deviceId))tx.set(indexPath,{ids:[...index.ids,body.deviceId]});
          return{enrolled:true};
        }
        if(body.op==='revoke'){
          // Keep a tombstone rather than trusting a best-effort queue deletion.
          const index=await tx.get(indexPath)??{ids:[]};tx.set(indexPath,{ids:index.ids.filter(id=>id!==body.deviceId)});
          tx.set(devicePath(body.deviceId),{revoked:true,tokenHash:null,state:null,pushToken:null,after:0});return{revoked:true};
        }
        if(body.op==='push'){
          if(typeof body.token!=='string'||body.token.length<1||body.token.length>4096||/[\r\n]/.test(body.token))fail(400,'invalid_push_token');
          tx.set(devicePath(body.deviceId),{...device,pushToken:body.token});return{registered:true};
        }
        if(body.op==='poll'){
          if(body.after!==undefined&&(!Number.isSafeInteger(body.after)||body.after<0||body.after>now+10))fail(400,'invalid_cursor');
          const messages=await tx.scan(`${devicePath(body.deviceId)}/messages`,33);
          const after=body.after??device.after??0;
          const live=[];
          for(const {path,value} of messages){if(value.envelope.expiresAt<=now)tx.delete(path);else if(value.envelope.createdAt>=after)live.push(value.envelope);}
          return{state:device.state?.expiresAt>now?device.state:null,messages:live.sort((a,b)=>a.createdAt-b.createdAt).slice(-32)};
        }
        if(body.op==='send'){
          const e=validateEnvelope(body.envelope,{macId:this.macId,deviceId:body.deviceId,direction:'c2s',kind:'command',now});
          if(!device.state||device.state.expiresAt<=now||device.state.epoch!==e.epoch)fail(409,'mac_unreachable_or_old_epoch');
          const queued=await tx.scan(commands,33);const old=queued.find(c=>c.path===`${commands}/${e.id}`)?.value;
          if(old){if(old.deviceId!==e.deviceId||old.fingerprint!==fingerprint(e))fail(409,'immutable_id_conflict');return{accepted:true};}
          const live=queued.filter(c=>c.value.envelope.expiresAt>now);
          if(live.length>=32)fail(429,'queue_full');
          for(const c of queued)if(c.value.envelope.expiresAt<=now)tx.delete(c.path);
          tx.set(`${commands}/${e.id}`,{deviceId:e.deviceId,envelope:e,fingerprint:fingerprint(e)});return{accepted:true};
        }
        if(!uuid(body.epoch))fail(400,'invalid_epoch');
        const groups=[['states','state'],['responses','response'],['events','event']];let count=0;
        for(const [field] of groups){if(body[field]!==undefined&&!Array.isArray(body[field]))fail(400,'invalid_batch');count+=(body[field]?.length??0);}
        if(count>16)fail(400,'batch_limit');
        const queued=await tx.scan(commands,33);const output=[];
        for(const c of queued){if(c.value.envelope.expiresAt<=now||c.value.envelope.epoch!==body.epoch)tx.delete(c.path);else output.push(c.value.envelope);}
        const replying=new Set(),retryEvents=[];
        for(const [field,kind] of groups)for(const e of body[field]??[]){
          validateEnvelope(e,{macId:this.macId,direction:'s2c',kind,epoch:kind==='state'?body.epoch:undefined,now});
          const d=await active(e.deviceId);
          if(kind==='state'){
            if(d.state&&d.state.epoch===e.epoch&&d.state.createdAt>e.createdAt)fail(409,'state_would_regress');
            tx.set(devicePath(e.deviceId),{...d,state:e});
          }else{
            const collection=`${devicePath(e.deviceId)}/messages`;const messages=await tx.scan(collection,33);
            const path=messagePath(e.deviceId,e.id),old=messages.find(m=>m.path===path)?.value;
            const digest=fingerprint(e);
            if(old&&old.fingerprint!==digest)fail(409,'immutable_id_conflict');
            const record=old??{envelope:e,fingerprint:digest,push:'new',claimUntil:0};
            if(kind==='response'){
              const original=queued.find(c=>c.value.envelope.id===e.id)?.value;
              if(original&&(original.deviceId!==e.deviceId||original.envelope.epoch!==e.epoch))fail(409,'wrong_response_owner');
              tx.delete(`${commands}/${e.id}`);replying.add(e.id);
            }
            for(const m of messages)if(m.value.envelope.expiresAt<=now)tx.delete(m.path);
            const live=messages.filter(m=>m.path!==path&&m.value.envelope.expiresAt>now).sort((a,b)=>a.value.envelope.createdAt-b.value.envelope.createdAt);
            while(live.length>=32)tx.delete(live.shift().path);
            if(kind==='event'&&d.pushToken&&record.push!=='sent'){
              if(record.claimUntil>now)retryEvents.push(e.id);
              else{record.push='claimed';record.claimUntil=now+30;record.claimId=randomUUID();pendingPush.push({path,devicePath:devicePath(e.deviceId),token:d.pushToken,envelope:e,claimId:record.claimId});}
            }
            tx.set(path,record);
          }
        }
        return{commands:output.filter(e=>!replying.has(e.id)).slice(0,16),retryEvents};
      });
      for(const p of pendingPush){
        // FCM is outside the database retry loop. A crash leaves a bounded lease;
        // Mac retries the same immutable event, and Android persists its ID claim.
        try{if(!this.push)throw new Error('Push unavailable');await this.push(p.token,p.envelope);}
        catch(error){
          if(error?.permanent){await this.store.transaction(async tx=>{const d=await tx.get(p.devicePath);const r=await tx.get(p.path);if(d?.pushToken===p.token)tx.set(p.devicePath,{...d,pushToken:null});if(r?.claimId===p.claimId)tx.set(p.path,{...r,push:'invalid_token',claimUntil:0});});}
          else result.retryEvents.push(p.envelope.id);
          continue;
        }
        await this.store.transaction(async tx=>{const r=await tx.get(p.path);if(r?.claimId===p.claimId)tx.set(p.path,{...r,push:'sent',claimUntil:0});});
      }
      return{status:200,body:result};
    }catch(e){return{status:e instanceof RelayError?e.status:503,body:{error:e instanceof RelayError?e.code:'relay_unavailable'}};}
  }
}
