import {test} from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('./draft-journal.ts',import.meta.url),'utf8');
const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const {DraftJournal}=await import('data:text/javascript;base64,'+Buffer.from(js).toString('base64'));
function storage(){const m=new Map();return {getItem:k=>m.get(k)||null,setItem:(k,v)=>m.set(k,v),removeItem:k=>m.delete(k)}}
test('auth/reload recovery retains idempotency ID and expected version and requires retry',()=>{
 const s=storage(),j=new DraftJournal(s,['alice','run','head']);const pending=[{id:'op',expected:4,op:{kind:'upsert_comment',item:{id:'c',file:'a',body:'Keep this'}}}];j.save(pending);
 const recovered=new DraftJournal(s,['alice','run','head']).restore();assert.equal(recovered[0].id,'op');assert.equal(recovered[0].expected,4);assert.equal(recovered[0].op.item.body,'Keep this');assert.match(recovered[0].error.message,/Retry/);
 for(const scope of [['bob','run','head'],['alice','other','head'],['alice','run','new']])assert.deepEqual(new DraftJournal(s,scope).restore(),[]);
 j.save([]);assert.deepEqual(j.restore(),[]);
});
test('storage failures are explicit rather than claiming durable recovery',()=>{
 const j=new DraftJournal({setItem(){throw Error('full')},getItem(){return null},removeItem(){}},['a']);assert.throws(()=>j.save([{id:'x',op:{kind:'delete_comment',id:'c'}}]),/full/);
});
