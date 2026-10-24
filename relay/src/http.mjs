export const makeHandler=getRelay=>async(req,res)=>{
  const started=performance.now(),cpuStart=process.cpuUsage();
  res.setHeader('Cache-Control','no-store');res.setHeader('Content-Type','application/json');res.setHeader('X-Content-Type-Options','nosniff');
  const send=(status,body)=>{
    const cpu=process.cpuUsage(cpuStart);
    // Diagnostic timings only; process CPU includes any concurrent invocation
    // sharing this instance and is not a provider billing measurement.
    res.setHeader('Server-Timing',`relay;dur=${(performance.now()-started).toFixed(3)}, process_cpu;dur=${((cpu.user+cpu.system)/1000).toFixed(3)}`);
    res.statusCode=status;res.end(JSON.stringify(body));
  };
  if(req.method!=='POST'){res.setHeader('Allow','POST');return send(405,{error:'method_not_allowed'});}
  if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']??''))return send(415,{error:'json_required'});
  if(!/^Bearer [^\r\n]{1,249}$/.test(req.headers.authorization??''))return send(401,{error:'unauthorized'});
  const length=Number(req.headers['content-length']);if(length>262144)return send(413,{error:'request_too_large'});
  try{
    let body=req.body;
    if(body===undefined){let size=0;const chunks=[];for await(const chunk of req){size+=Buffer.byteLength(chunk);if(size>262144)return send(413,{error:'request_too_large'});chunks.push(Buffer.from(chunk));}body=Buffer.concat(chunks).toString('utf8');}
    if(Buffer.byteLength(typeof body==='string'?body:JSON.stringify(body))>262144)return send(413,{error:'request_too_large'});
    if(typeof body==='string'||Buffer.isBuffer(body)){try{body=JSON.parse(body.toString());}catch{return send(400,{error:'invalid_json'});}}
    const relay=await getRelay(body);const result=await relay.handle(req.headers.authorization,body);send(result.status,result.body);
  }catch{send(503,{error:'relay_unavailable'});}
};
