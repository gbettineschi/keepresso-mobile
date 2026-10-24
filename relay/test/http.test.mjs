import test from 'node:test';import assert from 'node:assert/strict';import http from 'node:http';
import {makeHandler} from '../src/http.mjs';
async function server(fn){const server=http.createServer(makeHandler(async()=>({handle:async(auth,body)=>({status:auth==='Bearer fixture'?200:401,body:auth==='Bearer fixture'?{op:body.op}:{error:'unauthorized'}})})));await new Promise(r=>server.listen(0,'127.0.0.1',r));try{await fn(`http://127.0.0.1:${server.address().port}`);}finally{await new Promise(r=>server.close(r));}}
test('HTTP boundary rejects unsupported methods, bad JSON, missing auth and oversized bodies',async()=>{
  await server(async url=>{
    assert.equal((await fetch(url,{method:'GET'})).status,405);
    assert.equal((await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:'{}'})).status,401);
    assert.equal((await fetch(url,{method:'POST',headers:{authorization:'Bearer fixture','content-type':'application/json'},body:'{'})).status,400);
    assert.equal((await fetch(url,{method:'POST',headers:{authorization:'Bearer fixture','content-type':'text/plain'},body:'{}'})).status,415);
    assert.equal((await fetch(url,{method:'POST',headers:{authorization:'Bearer fixture','content-type':'application/json'},body:JSON.stringify({op:'poll',x:'a'.repeat(262145)})})).status,413);
    const r=await fetch(url,{method:'POST',headers:{authorization:'Bearer fixture','content-type':'application/json'},body:'{"op":"poll"}'});
    assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');assert.deepEqual(await r.json(),{op:'poll'});
  });
});
