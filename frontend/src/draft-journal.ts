import type {DraftItem, Pending} from './draft-queue';
// Session-local: survive auth navigation/reload without sharing drafts across tabs,
// accounts, runs or head revisions. Recovery requires an explicit Retry action.
export class DraftJournal<T extends DraftItem> {
 private key:string;
 constructor(private storage:Pick<Storage,'getItem'|'setItem'|'removeItem'>,scope:string[]){
  this.key='codeturtle.pending.v1:'+JSON.stringify(scope);
 }
 save(pending:Pending<T>[]){
  if(!pending.length){this.storage.removeItem(this.key);return;}
  this.storage.setItem(this.key,JSON.stringify({at:Date.now(),pending:pending.map(({id,op,expected})=>({id,op,expected}))}));
 }
 restore():Pending<T>[]{
  const raw=this.storage.getItem(this.key);if(!raw)return [];
  try{
   const data=JSON.parse(raw);
   if(!Array.isArray(data.pending)||!data.pending.every((p:Pending<T>)=>typeof p.id==='string'&&p.op&&['upsert_comment','upsert_decision','delete_comment','delete_decision'].includes(p.op.kind)&&('item' in p.op?typeof p.op.item?.id==='string'&&typeof p.op.item?.file==='string':typeof p.op.id==='string')&&(p.expected===undefined||Number.isSafeInteger(p.expected)&&p.expected>=0)))throw Error();
   return data.pending.map((p:Pending<T>)=>({...p,error:new Error('Recovered unsaved edits. Retry to save them.')}));
  }catch{throw new Error('Unable to recover saved edits. Keep this tab open; do not clear browser storage.');}
 }
}
