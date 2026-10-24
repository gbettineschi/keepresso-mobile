import {initializeApp,getApps,cert} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {getMessaging} from 'firebase-admin/messaging';
import {FirestoreStore} from './firestore.mjs';
import {Relay} from './relay.mjs';
let initialized;
export function configured(){return Boolean(process.env.FIREBASE_SERVICE_ACCOUNT&&/^[0-9a-f]{64}$/.test(process.env.RELAY_MAC_TOKEN_SHA256??''));}
export function getRelay(body){
  if(!configured())throw new Error('Relay is not configured');
  if(!initialized){const account=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);const app=getApps().find(a=>a.name==='keepresso-relay')??initializeApp({credential:cert(account),projectId:account.project_id},'keepresso-relay');initialized={store:new FirestoreStore(getFirestore(app)),messaging:getMessaging(app)};}
  // One self-hosted owner controls this bootstrap secret. Optionally pin a Mac
  // ID in env; otherwise multiple Macs owned by that same person are isolated by ID.
  const macId=process.env.RELAY_MAC_ID??body?.macId;
  return new Relay({store:initialized.store,macId,macTokenHash:process.env.RELAY_MAC_TOKEN_SHA256,push:async(token,envelope)=>{
    const text=JSON.stringify(envelope);const data=Buffer.byteLength(text)<=3500?{relayEnvelope:text}:{relayWake:'1',macId:envelope.macId,deviceId:envelope.deviceId};
    try{await initialized.messaging.send({token,data,android:{priority:'high',ttl:Math.max(0,envelope.expiresAt*1000-Date.now()),...(data.relayWake?{collapseKey:'keepresso-relay-sync'}:{})}});}
    catch(error){if(['messaging/registration-token-not-registered','messaging/invalid-registration-token'].includes(error?.code))error.permanent=true;throw error;}
  }});
}
