// Acknowledged server state plus ordered local operations. No whole-draft writes.
export type DraftItem = {id:string;file:string};
export type DraftOperation<T extends DraftItem = DraftItem> =
 | {kind:'upsert_comment'|'upsert_decision';item:T}
 | {kind:'delete_comment'|'delete_decision';id:string};
export type Draft<T extends DraftItem>={comments:T[];decisions:T[]};
export function applyOperation<T extends DraftItem>(draft:Draft<T>, op:DraftOperation<T>):Draft<T>{
 const bucket=op.kind.endsWith('comment')?'comments':'decisions';
 const next={comments:[...draft.comments],decisions:[...draft.decisions]};
 if('item' in op){const item=op.item;next[bucket]=next[bucket].filter(x=>bucket==='comments'?x.id!==item.id:x.file!==item.file);next[bucket].push(item);}
 else next[bucket]=next[bucket].filter(x=>x.id!==op.id);
 return next;
}
export type Pending<T extends DraftItem>={id:string;op:DraftOperation<T>;expected?:number;error?:Error};
export class DraftQueue<T extends DraftItem>{
 pending:Pending<T>[]=[];
 running=false;
 private flight:Promise<void>|undefined;
 constructor(public base:Draft<T>,public version:number,private send:(op:DraftOperation<T>,id:string,version:number)=>Promise<{version:number}>,private changed:()=>void){}
 get view(){return this.pending.reduce((d,p)=>applyOperation(d,p.op),this.base);}
 get error(){return this.pending[0]?.error;}
 enqueue(op:DraftOperation<T>){this.pending.push({id:crypto.randomUUID(),op});this.changed();void this.pump();}
 private pump():Promise<void>{
  if(this.flight)return this.flight;
  this.flight=this.drain().finally(()=>{this.flight=undefined;this.changed();if(this.pending.length&&!this.error)void this.pump();});
  return this.flight;
 }
 private async drain(){
  this.running=true;
  try{while(this.pending.length&&!this.pending[0].error){
   const next=this.pending[0];next.expected??=this.version;this.changed();
   try{const ack=await this.send(next.op,next.id,next.expected);this.base=applyOperation(this.base,next.op);this.version=ack.version;this.pending.shift();}
   catch(e){next.error=e instanceof Error?e:new Error(String(e));}
   this.changed();
  }}finally{this.running=false;}
 }
 async flush(){do{await this.pump();if(this.error)throw this.error;}while(this.pending.length);}
 async retry(refresh?:()=>Promise<{draft:Draft<T>;version:number}>){
  await this.flight;
  if(refresh){const fresh=await refresh();this.base=fresh.draft;this.version=fresh.version;for(const p of this.pending){p.id=crypto.randomUUID();p.expected=undefined;}}
  for(const p of this.pending)p.error=undefined;
  this.changed();await this.flush();
 }
}
