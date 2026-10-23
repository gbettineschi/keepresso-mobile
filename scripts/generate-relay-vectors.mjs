// Independent public fixtures. Never use these deterministic keys/nonces live.
import {createHash,hkdfSync,createCipheriv,createHmac} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
const old=JSON.parse(readFileSync(new URL('../shared/vectors.json',import.meta.url)));
const {macId,deviceId,deviceKey,plaintext}=old;
const hash=s=>createHash('sha256').update(s).digest();
const derive=info=>Buffer.from(hkdfSync('sha256',Buffer.from(deviceKey,'base64'),hash(`${macId}\n${deviceId}`),Buffer.from(`keepresso-mobile/relay/v1/${info}`),32));
const c2s=derive('c2s'),s2c=derive('s2c'),phoneBearer=derive('phone-access').toString('base64');
const envelope={version:1,macId,deviceId,id:'33333333-3333-4333-8333-333333333333',epoch:'44444444-4444-4444-8444-444444444444',direction:'c2s',kind:'command',createdAt:1792756800,expiresAt:1792756830,nonce:Buffer.from(Array.from({length:12},(_,i)=>i+80)).toString('base64')};
const aad=['keepresso-mobile/relay/v1',macId,deviceId,envelope.id,envelope.epoch,envelope.direction,envelope.kind,envelope.createdAt,envelope.expiresAt].join('\n');
const cipher=createCipheriv('aes-256-gcm',c2s,Buffer.from(envelope.nonce,'base64'));cipher.setAAD(Buffer.from(aad));
envelope.ciphertext=Buffer.concat([cipher.update(plaintext),cipher.final(),cipher.getAuthTag()]).toString('base64');
const macBearer=Buffer.from(Array.from({length:32},(_,i)=>i+100)).toString('base64');
const macTokenHash=hash(macBearer).toString('hex'),phoneTokenHash=hash(phoneBearer).toString('hex');
const ticketTranscript=`keepresso-mobile/relay/v1/access-ticket\n${macId}\n${deviceId}\n${phoneTokenHash}`;
const authTicket=createHmac('sha256',macTokenHash).update(ticketTranscript).digest('base64');
const fixture={warning:'PUBLIC FIXTURES ONLY',macId,deviceId,deviceKey,c2s:c2s.toString('base64'),s2c:s2c.toString('base64'),phoneBearer,phoneTokenHash,macBearer,macTokenHash,ticketTranscript,authTicket,aad,plaintext,envelope};
writeFileSync(new URL('../shared/relay-vectors.json',import.meta.url),JSON.stringify(fixture,null,2)+'\n');
