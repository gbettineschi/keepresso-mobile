import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
import {Relay} from '../src/relay.mjs';
import {MemoryStore} from './memory-store.mjs';
const fixture=JSON.parse(readFileSync(new URL('../../shared/relay-vectors.json',import.meta.url)));
const hash=s=>createHash('sha256').update(s).digest('hex');
const macToken=fixture.macBearer;
const macId=fixture.macId,deviceId=fixture.deviceId,epoch=fixture.envelope.epoch;
function setup(){
  const store=new MemoryStore();let now=fixture.envelope.createdAt;const pushes=[];
  const relay=new Relay({store,macId,macTokenHash:hash(macToken),now:()=>now,push:async(token,envelope)=>{pushes.push({token,envelope});}});
  const mac=body=>relay.handle(`Bearer ${macToken}`,{macId,...body});
  const phone=body=>relay.handle(`Bearer ${fixture.phoneBearer}.${fixture.authTicket}`,{macId,deviceId,...body});
  const env=(kind='state',changes={})=>({...fixture.envelope,id:randomUUID(),direction:kind==='command'?'c2s':'s2c',kind,expiresAt:now+(kind==='state'?15:kind==='event'?300:30),...changes});
  const enroll=()=>mac({op:'enroll',deviceId,tokenHash:fixture.phoneTokenHash});
  const state=()=>mac({op:'sync',epoch,states:[env()]});
  return{store,relay,mac,phone,env,enroll,state,pushes,advance:s=>now+=s};
}
test('untrusted token cannot enroll a device',async()=>{
  const s=setup();assert.equal((await s.relay.handle('Bearer forged',{op:'enroll',macId,deviceId,tokenHash:fixture.phoneTokenHash})).status,401);
  assert.equal(s.store.records.size,0);
});
test('owner enrollment preserves an existing phone key and phone cannot impersonate Mac',async()=>{
  const s=setup();assert.equal((await s.enroll()).status,200);
  assert.equal((await s.phone({op:'enroll',tokenHash:fixture.phoneTokenHash})).status,401);
  assert.equal((await s.phone({op:'poll'})).status,200);
});
test('revocation denies incoming/outgoing access and stale reenrollment does not resurrect cached state',async()=>{
  const s=setup();await s.enroll();await s.state();await s.mac({op:'revoke',deviceId});
  assert.equal((await s.phone({op:'poll'})).status,401);
  assert.equal((await s.state()).status,403);
  await s.enroll();assert.equal((await s.phone({op:'poll'})).body.state,null);
});
test('one immutable command is returned across duplicate concurrent submissions',async()=>{
  const s=setup();await s.enroll();await s.state();const envelope=s.env('command');
  const [a,b]=await Promise.all([s.phone({op:'send',envelope}),s.phone({op:'send',envelope})]);
  assert.equal(a.status,200);assert.equal(b.status,200);
  const r=await s.mac({op:'sync',epoch});assert.deepEqual(r.body.commands,[envelope]);
  assert.equal((await s.phone({op:'send',envelope:{...envelope,ciphertext:Buffer.alloc(16,4).toString('base64')}})).status,409);
});
test('old epoch or stale Mac cannot accept a queued power command',async()=>{
  const s=setup();await s.enroll();await s.state();
  assert.equal((await s.phone({op:'send',envelope:s.env('command',{epoch:randomUUID()})})).status,409);
  s.advance(16);assert.equal((await s.phone({op:'send',envelope:s.env('command',{createdAt:fixture.envelope.createdAt+16,expiresAt:fixture.envelope.createdAt+46})})).status,409);
});
test('commands from previous epoch and expired commands are never delivered after reconnect',async()=>{
  const s=setup();await s.enroll();await s.state();await s.phone({op:'send',envelope:s.env('command')});
  assert.deepEqual((await s.mac({op:'sync',epoch:randomUUID()})).body.commands,[]);
  s.advance(31);assert.deepEqual((await s.mac({op:'sync',epoch})).body.commands,[]);
});
test('response removes queued command and remains available only to matching phone',async()=>{
  const s=setup();await s.enroll();await s.state();const command=s.env('command');await s.phone({op:'send',envelope:command});
  const response=s.env('response',{id:command.id});assert.equal((await s.mac({op:'sync',epoch,responses:[response]})).status,200);
  assert.deepEqual((await s.mac({op:'sync',epoch})).body.commands,[]);
  assert.deepEqual((await s.phone({op:'poll'})).body.messages,[response]);
  assert.equal((await s.phone({op:'poll',deviceId:randomUUID()})).status,401);
});
test('notification upload retries are immutable, push only once after success, and expiry is enforced',async()=>{
  const s=setup();await s.enroll();await s.phone({op:'push',token:'test-FCM-token'});const event=s.env('event');
  assert.equal((await s.mac({op:'sync',epoch,events:[event]})).status,200);
  assert.equal((await s.mac({op:'sync',epoch,events:[event]})).status,200);
  assert.equal(s.pushes.length,1);assert.deepEqual(s.pushes[0].envelope,event);
  s.advance(301);assert.deepEqual((await s.phone({op:'poll'})).body.messages,[]);
});
test('unknown fields, routes, encodings and oversized inputs fail closed',async()=>{
  const s=setup();await s.enroll();await s.state();
  for(const envelope of [s.env('command',{nonce:'a'}),s.env('command',{deviceId:randomUUID()}),s.env('command',{direction:'s2c'}),s.env('command',{createdAt:fixture.envelope.createdAt+11}),s.env('command',{expiresAt:fixture.envelope.createdAt+31}),s.env('command',{version:2}),s.env('command',{ciphertext:'x'.repeat(70000)})]) assert.equal((await s.phone({op:'send',envelope})).status,400);
  assert.equal((await s.phone({op:'execute_shell'})).status,400);
  assert.equal((await s.phone({op:'send',envelope:s.env('command'),extra:'untrusted'})).status,400);
});
test('bounded pending queue refuses additional commands instead of discarding an uncertain outcome',async()=>{
  const s=setup();await s.enroll();await s.state();
  for(let i=0;i<32;i++)assert.equal((await s.phone({op:'send',envelope:s.env('command')})).status,200);
  assert.equal((await s.phone({op:'send',envelope:s.env('command')})).status,429);
  assert.equal((await s.mac({op:'sync',epoch})).body.commands.length,16);
});
test('stale state upload cannot overwrite a newer state in the same epoch',async()=>{
  const s=setup();await s.enroll();const state=s.env();await s.mac({op:'sync',epoch,states:[{...state,createdAt:state.createdAt+1,expiresAt:state.expiresAt+1}]});
  assert.equal((await s.mac({op:'sync',epoch,states:[state]})).status,409);
});
test('device enrollment is bounded to eight active phones atomically',async()=>{
  const s=setup();for(let i=0;i<8;i++)assert.equal((await s.mac({op:'enroll',deviceId:randomUUID(),tokenHash:fixture.phoneTokenHash})).status,200);
  assert.equal((await s.enroll()).status,429);
});
test('failed push is recoverable after its durable lease without changing event identity',async()=>{
  const s=setup();await s.enroll();await s.phone({op:'push',token:'test-FCM-token'});const event=s.env('event');
  s.relay.push=async()=>{throw new Error('network unavailable');};
  const first=await s.mac({op:'sync',epoch,events:[event]});assert.equal(first.status,200);assert.deepEqual(first.body.retryEvents,[event.id]);
  const second=await s.mac({op:'sync',epoch,events:[event]});assert.equal(second.status,200);assert.deepEqual(second.body.retryEvents,[event.id]);
  s.advance(31);let delivered;
  s.relay.push=async(_,e)=>{delivered=e;};
  assert.equal((await s.mac({op:'sync',epoch,events:[event]})).status,200);
  assert.deepEqual(delivered,event);
});
test('public forged phone bearer fails before any database operation',async()=>{
  const s=setup();let touched=false;s.relay.store={transaction(){touched=true;throw new Error('Unexpected database access');}};
  assert.equal((await s.relay.handle('Bearer invalid.ticket',{op:'poll',macId,deviceId})).status,401);assert.equal(touched,false);
});
test('revoked device churn cannot bypass eight active phone limit',async()=>{
  const s=setup();for(let i=0;i<10;i++){const id=randomUUID();await s.mac({op:'enroll',deviceId:id,tokenHash:fixture.phoneTokenHash});await s.mac({op:'revoke',deviceId:id});}
  for(let i=0;i<8;i++)assert.equal((await s.mac({op:'enroll',deviceId:randomUUID(),tokenHash:fixture.phoneTokenHash})).status,200);
  assert.equal((await s.enroll()).status,429);
});
test('permanently invalid FCM token does not obstruct command polling',async()=>{
  const s=setup();await s.enroll();await s.state();await s.phone({op:'push',token:'test-FCM-token'});const command=s.env('command');await s.phone({op:'send',envelope:command});
  s.relay.push=async()=>{throw Object.assign(new Error('Unregistered token'),{permanent:true});};
  const r=await s.mac({op:'sync',epoch,events:[s.env('event')]});assert.equal(r.status,200);assert.deepEqual(r.body.commands,[command]);assert.deepEqual(r.body.retryEvents,[]);
  assert.equal(s.store.records.get(`macs/${macId}/devices/${deviceId}`).pushToken,null);
});
test('envelope key order does not turn an idempotent upload into conflicting ciphertext',async()=>{
  const s=setup();await s.enroll();await s.state();const envelope=s.env('command');
  assert.equal((await s.phone({op:'send',envelope})).status,200);
  const reordered=Object.fromEntries(Object.entries(envelope).reverse());
  assert.equal((await s.phone({op:'send',envelope:reordered})).status,200);
});
