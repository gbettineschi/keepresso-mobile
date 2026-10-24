#!/usr/bin/env node
// Synthetic protocol peers only. Never imports a native power adapter.
import assert from 'node:assert/strict';import {parseArgs}from'node:util';import{readFileSync,writeFileSync}from'node:fs';import{createHash,createHmac,hkdfSync,randomBytes,randomUUID,createCipheriv,createDecipheriv}from'node:crypto';
const {values}=parseArgs({options:{url:{type:'string'},'mac-bearer':{type:'string'},report:{type:'string'},'cleanup-account':{type:'string'}}});
const url=new URL(values.url);assert.equal(url.protocol,'https:');assert.equal(url.pathname,'/');
const macBearer=readFileSync(values['mac-bearer'],'utf8').trim(),macId=randomUUID(),deviceId=randomUUID(),epoch=randomUUID(),deviceKey=randomBytes(32);
const sha=s=>createHash('sha256').update(s).digest();const salt=sha(`${macId}\n${deviceId}`);
const key=direction=>Buffer.from(hkdfSync('sha256',deviceKey,salt,Buffer.from(`keepresso-mobile/relay/v1/${direction}`),32));
const phoneBearer=key('phone-access').toString('base64'),tokenHash=sha(phoneBearer).toString('hex');
const ticket=createHmac('sha256',sha(macBearer).toString('hex')).update(`keepresso-mobile/relay/v1/access-ticket\n${macId}\n${deviceId}\n${tokenHash}`).digest('base64');
const auth={mac:macBearer,phone:`${phoneBearer}.${ticket}`},latencies=[];
async function call(role,op,fields={},expected=200){
  const started=performance.now();const r=await fetch(new URL('/api/relay',url),{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${auth[role]}`},body:JSON.stringify({op,macId,...(role==='phone'?{deviceId}:{}),...fields}),redirect:'error',signal:AbortSignal.timeout(20000)});
  const ms=performance.now()-started;latencies.push({op,ms:Math.round(ms),status:r.status,serverTiming:r.headers.get('server-timing')});assert.equal(r.status,expected,`${op} returned unexpected HTTP status`);return r.json();
}
const aad=e=>Buffer.from(['keepresso-mobile/relay/v1',e.macId,e.deviceId,e.id,e.epoch,e.direction,e.kind,e.createdAt,e.expiresAt].join('\n'));
function seal(kind,plaintext,id=randomUUID()){
  const createdAt=Math.floor(Date.now()/1000),direction=kind==='command'?'c2s':'s2c',nonce=randomBytes(12),e={version:1,macId,deviceId,id,epoch,direction,kind,createdAt,expiresAt:createdAt+({state:15,command:30,response:120,event:300}[kind]),nonce:nonce.toString('base64')};
  const cipher=createCipheriv('aes-256-gcm',key(direction),nonce);cipher.setAAD(aad(e));e.ciphertext=Buffer.concat([cipher.update(plaintext),cipher.final(),cipher.getAuthTag()]).toString('base64');return e;
}
function open(e){const packed=Buffer.from(e.ciphertext,'base64'),d=createDecipheriv('aes-256-gcm',key(e.direction),Buffer.from(e.nonce,'base64'));d.setAAD(aad(e));d.setAuthTag(packed.subarray(-16));return Buffer.concat([d.update(packed.subarray(0,-16)),d.final()]).toString();}
let report;
try{
  const denied=await fetch(new URL('/api/relay',url),{method:'POST',headers:{'content-type':'application/json'},body:'{}',signal:AbortSignal.timeout(20000)});assert.equal(denied.status,401);
  await call('mac','enroll',{deviceId,tokenHash});
  const snapshot={capturedAt:new Date().toISOString(),macName:'Synthetic relay check',mac:{lock:'unknown',display:'unknown',lid:'unknown',batteryPercent:null,powerSource:'unknown',temperatureC:null,temperatureSensor:null,thermal:'unknown'},keepresso:{appRunning:false,version:null,isActive:false,endsAt:null,triggersEnabled:null,triggersPaused:null,sessionKind:'unknown',safetyPause:'unknown'},capabilities:{startManual:false,stopManual:false,pauseTriggers:false,resumeTriggers:false,sleepNow:false,refreshTriggers:false},triggers:{state:'not_checked',checkedAt:null,combined:null,rules:[],message:null},reminders:{enabled:true,intervalSeconds:3600,snoozedUntil:null,endedAwakeDelaySeconds:120}};
  const stateText=JSON.stringify({type:'relay_state',epoch,revision:1,snapshot});await call('mac','sync',{epoch,states:[seal('state',stateText)]});
  const first=await call('phone','poll');assert.equal(open(first.state),stateText);
  const id=randomUUID(),issued=new Date(),request=JSON.stringify({type:'request',id,action:'status',issuedAt:issued.toISOString(),expiresAt:new Date(issued.getTime()+30000).toISOString()});const envelope=seal('command',request,id);
  await call('phone','send',{envelope});await call('phone','send',{envelope});
  const delivered=await call('mac','sync',{epoch});assert.equal(delivered.commands.length,1);assert.equal(open(delivered.commands[0]),request);
  const responseText=JSON.stringify({type:'response',id,status:'ok',snapshot});await call('mac','sync',{epoch,responses:[seal('response',responseText,id)]});
  const returned=await call('phone','poll');assert.equal(open(returned.messages.find(e=>e.id===id)),responseText);
  const corrupt={...envelope,ciphertext:Buffer.alloc(Buffer.from(envelope.ciphertext,'base64').length).toString('base64')};assert.throws(()=>open(corrupt));
  for(let i=0;i<10;i++)await call('mac','sync',{epoch});
  await call('mac','revoke',{deviceId});await call('phone','poll',{},401);
  const warm=latencies.slice(1).map(x=>x.ms).sort((a,b)=>a-b);
  report={checkedAt:new Date().toISOString(),url:url.origin,result:'passed',kind:'synthetic encrypted peers; no native adapter or physical phone',checks:['unauthorized401','Firestore-backed enrollment','encrypted state roundtrip','idempotent duplicate command upload','encrypted command/response roundtrip','tamper rejection by recipient','revocation401'],firstAuthenticatedRequestMs:latencies[0].ms,warmP50Ms:warm[Math.floor(warm.length*.5)],warmP95Ms:warm[Math.min(warm.length-1,Math.floor(warm.length*.95))],samples:latencies};
  console.log(JSON.stringify(report,null,2));if(values.report)writeFileSync(values.report,JSON.stringify(report,null,2)+'\n');
}finally{
  // Remove only this script's random synthetic Mac subtree, never real devices.
  if(values['cleanup-account']){
    const {initializeApp,cert,deleteApp}=await import('firebase-admin/app');const {getFirestore}=await import('firebase-admin/firestore');const account=JSON.parse(readFileSync(values['cleanup-account'],'utf8'));
    const app=initializeApp({credential:cert(account),projectId:account.project_id},`smoke-${macId}`);try{await getFirestore(app).recursiveDelete(getFirestore(app).doc(`macs/${macId}`));}finally{await deleteApp(app);}
  }
}
