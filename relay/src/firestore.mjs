// Buffer writes until all reads complete: Firestore requires read-before-write,
// while domain logic also needs read-your-writes within a single transaction.
export class FirestoreStore {
  constructor(db){this.db=db;}
  transaction(fn){
    return this.db.runTransaction(async native=>{
      const writes=new Map(),cache=new Map();
      const get=async path=>{
        if(writes.has(path))return structuredClone(writes.get(path));
        if(!cache.has(path)){const snap=await native.get(this.db.doc(path));cache.set(path,snap.exists?snap.data():null);}
        return structuredClone(cache.get(path));
      };
      const scan=async(collection,limit=33)=>{
        const key=`query:${collection}:${limit}`;
        if(!cache.has(key)){
          const snap=await native.get(this.db.collection(collection).limit(limit));
          const records=snap.docs.map(d=>({path:d.ref.path,value:d.data()}));cache.set(key,records);
          for(const r of records)cache.set(r.path,r.value);
        }
        const records=new Map(cache.get(key).map(r=>[r.path,r.value]));
        for(const [path,value]of writes)if(path.startsWith(collection+'/')&&!path.slice(collection.length+1).includes('/')){if(value===null)records.delete(path);else records.set(path,value);}
        return [...records].slice(0,limit).map(([path,value])=>({path,value:structuredClone(value)}));
      };
      const result=await fn({get,scan,set:(path,value)=>writes.set(path,structuredClone(value)),delete:path=>writes.set(path,null)});
      for(const [path,value]of writes){if(value===null)native.delete(this.db.doc(path));else native.set(this.db.doc(path),value);}
      return result;
    },{maxAttempts:3});
  }
}
