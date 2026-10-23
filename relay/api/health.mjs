import {configured} from '../src/firebase.mjs';
export default function(_req,res){res.setHeader('Cache-Control','no-store');res.setHeader('Content-Type','application/json');res.statusCode=configured()?200:503;res.end(JSON.stringify({version:1,configured:configured()}));}
