#!/usr/bin/env node
// Secret values travel through stdin, never command arguments or console output.
import {parseArgs} from 'node:util';import {readFileSync,writeFileSync,mkdirSync,existsSync,chmodSync} from 'node:fs';import {resolve,join} from 'node:path';import {createHash,randomBytes,createPrivateKey} from 'node:crypto';import {spawnSync} from 'node:child_process';
const {values}=parseArgs({options:{scope:{type:'string'},'service-account':{type:'string'},'private-dir':{type:'string'},'check-only':{type:'boolean',default:false}}});
for(const key of ['scope','service-account','private-dir'])if(!values[key])throw new Error(`Missing --${key}`);
const linked=JSON.parse(readFileSync(resolve('.vercel/project.json'),'utf8'));
if(linked.orgId!==values.scope)throw new Error('--scope must match the linked Vercel organization ID');
const raw=readFileSync(values['service-account'],'utf8'),account=JSON.parse(raw);
if(account.type!=='service_account'||!account.project_id||!account.client_email?.endsWith('.gserviceaccount.com'))throw new Error('Not a Firebase service-account file');
createPrivateKey(account.private_key);
console.log(`Target: ${linked.projectName}; Firebase project: ${account.project_id}.`);
if(values['check-only']){console.log('Checked file format and scope; no credentials uploaded or generated.');process.exit(0);}
const directory=resolve(values['private-dir']);mkdirSync(directory,{recursive:true,mode:0o700});chmodSync(directory,0o700);
const bearerPath=join(directory,'mac-bearer.txt');
if(!existsSync(bearerPath))writeFileSync(bearerPath,randomBytes(32).toString('base64'),{mode:0o600,flag:'wx'});
chmodSync(bearerPath,0o600);const bearer=readFileSync(bearerPath,'utf8').trim();
if(Buffer.from(bearer,'base64').length!==32||Buffer.from(bearer,'base64').toString('base64')!==bearer)throw new Error('Invalid independent Mac bearer file');
const data={FIREBASE_SERVICE_ACCOUNT:raw,RELAY_MAC_TOKEN_SHA256:createHash('sha256').update(bearer).digest('hex')};
for(const [name,value]of Object.entries(data)){
  const r=spawnSync('vercel',['env','add',name,'production','--scope',values.scope,'--sensitive'],{input:value,encoding:'utf8'});
  if(r.status!==0)throw new Error(`Could not add ${name}. Inspect the project's variable names before retrying; existing values are never overwritten by this script.`);
  console.log(`Stored ${name} in production server configuration.`);
}
console.log(`Mac bearer retained privately at ${bearerPath}. Paste it only into the Mac helper's Internet configuration.`);
