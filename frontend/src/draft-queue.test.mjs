import {test} from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('./draft-queue.ts',import.meta.url),'utf8');
const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
const {DraftQueue}=await import('data:text/javascript;base64,'+Buffer.from(js).toString('base64'));
const empty=()=>({comments:[],decisions:[]});
const comment=(id)=>({kind:'upsert_comment',item:{id,file:'a',body:id}});
test('optimistic edits appear immediately and serial saves preserve later edits',async()=>{
 const releases=[];const calls=[];
 const q=new DraftQueue(empty(),0,(op,id,version)=>{calls.push({op,id,version});return new Promise(resolve=>releases.push(()=>resolve({version:version+1})));},()=>{});
 q.enqueue(comment('a'));q.enqueue(comment('b'));assert.equal(q.view.comments.length,2);assert.equal(calls.length,1);
 releases.shift()();await new Promise(r=>setImmediate(r));assert.equal(calls.length,2);assert.equal(calls[1].version,1);assert.equal(q.view.comments.length,2);
 releases.shift()();await q.flush();assert.equal(q.pending.length,0);assert.equal(q.base.comments.length,2);
});
test('lost response retries the same id and version; publish flush rejects until saved',async()=>{
 const ids=[];let lost=true;
 const q=new DraftQueue(empty(),4,async(op,id,version)=>{ids.push([id,version]);if(lost)throw Error('offline');return {version:5};},()=>{});
 q.enqueue(comment('a'));await assert.rejects(q.flush(),/offline/);assert.equal(q.view.comments[0].body,'a');lost=false;await q.retry();assert.deepEqual(ids[0],ids[1]);assert.equal(q.base.comments.length,1);
});
test('explicit conflict retry refreshes other-tab edits before replaying local operations',async()=>{
 let conflict=true;
 const q=new DraftQueue(empty(),0,async(op,id,version)=>{if(conflict)throw Error('draft_conflict');assert.equal(version,3);return {version:4};},()=>{});
 q.enqueue(comment('mine'));await assert.rejects(q.flush());conflict=false;
 await q.retry(async()=>({draft:{comments:[{id:'theirs',file:'b'}],decisions:[]},version:3}));
 assert.deepEqual(q.base.comments.map(x=>x.id),['theirs','mine']);
});
test('delete and file decision operations cannot replace unrelated drafts',async()=>{
 const q=new DraftQueue({comments:[{id:'a',file:'a'},{id:'b',file:'b'}],decisions:[]},0,async(_op,_id,v)=>({version:v+1}),()=>{});
 q.enqueue({kind:'delete_comment',id:'a'});q.enqueue({kind:'upsert_decision',item:{id:'d',file:'a'}});await q.flush();assert.deepEqual(q.base.comments.map(x=>x.id),['b']);assert.equal(q.base.decisions.length,1);
});
test('enqueue from a completion callback is not stranded behind the previous flight',async()=>{
 let added=false;let q;
 q=new DraftQueue(empty(),0,async(_op,_id,v)=>({version:v+1}),()=>{
  if(q&&!q.running&&q.base.comments.length===1&&!added){added=true;q.enqueue(comment('later'));}
 });
 q.enqueue(comment('first'));await q.flush();assert.deepEqual(q.base.comments.map(x=>x.id),['first','later']);assert.equal(q.pending.length,0);
});
