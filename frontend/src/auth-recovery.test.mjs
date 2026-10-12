import {test} from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {readFile} from 'node:fs/promises';
const moduleUrl=source=>'data:text/javascript;base64,'+Buffer.from(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText).toString('base64');
const queue=moduleUrl(await readFile(new URL('./draft-queue.ts',import.meta.url),'utf8'));
const journal=moduleUrl(await readFile(new URL('./draft-journal.ts',import.meta.url),'utf8'));
const workspace=(await readFile(new URL('./workspace.ts',import.meta.url),'utf8')).replace("'./draft-queue'",JSON.stringify(queue)).replace("'./draft-journal'",JSON.stringify(journal));
const page={draft_scope:'workos-user-scope',csrf:'csrf',review:{identity:{head:'head'},title:'PR'},reviewer:{login:'alice',eligible_owners:[]},files:[],state:{draft:{comments:[],decisions:[]},events:[],version:1},admin:false};
const settle=()=>new Promise(resolve=>setTimeout(resolve,20));
test('401 preserves queued comment across login, retains operation identity, and saves on explicit retry',async()=>{
 const old={fetch:globalThis.fetch,location:globalThis.location,document:globalThis.document,sessionStorage:globalThis.sessionStorage};
 const data=new Map();const requests=[];let reject=true;let composing=true;
 Object.assign(globalThis,{location:{search:'?run=run',pathname:'/',href:''},document:{querySelectorAll:()=>composing?[{value:'unsaved text'}]:[]},sessionStorage:{getItem:k=>data.get(k)||null,setItem:(k,v)=>data.set(k,v),removeItem:k=>data.delete(k)},fetch:async(path,options)=>{
  if(!options.body)return {ok:true,status:200,json:async()=>structuredClone(page)};
  requests.push(JSON.parse(options.body));
  return reject?{ok:false,status:401}:{ok:true,status:200,json:async()=>({version:2})};
 }});
 try{
  const first=await import(moduleUrl(workspace)+'#first');await first.load();
  first.upsertComment({id:'c',file:'a',user:'alice',revision:'r',side:'RIGHT',line:1,body:'Keep my comment',replyTo:null});
  await settle();
  assert.equal(location.href,'');assert.match(first.saveError(),/Save or copy/);
  composing=false;await assert.rejects(first.retryDrafts(),/sign in/);
  assert.match(location.href,/auth\/login/);assert.equal(data.size,1);
  reject=false;
  const afterLogin=await import(moduleUrl(workspace)+'#after-login');await afterLogin.load();
  assert.equal(afterLogin.state.drafts[0].body,'Keep my comment');
  assert.match(afterLogin.saveError(),/Recovered/);assert.equal(requests.length,2);
  await afterLogin.retryDrafts();
  assert.equal(requests[2].operation_id,requests[0].operation_id);
  assert.equal(requests[2].expected_version,requests[0].expected_version);
  assert.equal(afterLogin.saving(),0);assert.equal(data.size,0);
 }finally{Object.assign(globalThis,old);}
});
