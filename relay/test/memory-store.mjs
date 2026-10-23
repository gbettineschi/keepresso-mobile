// Atomic test double at the external database boundary, not a production fallback.
export class MemoryStore {
  records=new Map(); tail=Promise.resolve();
  async transaction(fn) {
    const previous=this.tail;let unlock;this.tail=new Promise(r=>unlock=r);await previous;
    const records=structuredClone(this.records);
    try {
      const result=await fn({
        get:async path=>structuredClone(records.get(path)??null),
        scan:async (collection,limit=33)=>[...records].filter(([path])=>path.startsWith(collection+'/')&&path.slice(collection.length+1).indexOf('/')<0).slice(0,limit).map(([path,value])=>({path,value:structuredClone(value)})),
        set:(path,value)=>records.set(path,structuredClone(value)),delete:path=>records.delete(path)
      });this.records=records;return result;
    } finally{unlock();}
  }
}
