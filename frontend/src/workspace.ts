import {DraftJournal} from './draft-journal';
import {DraftQueue, type DraftOperation} from './draft-queue';
export type Side='LEFT'|'RIGHT';
export type Decision={id:string;file:string;user:string;revision:string;kind:'approve'|'changes';body:string;owners?:string[]};
export type Comment={id:string;file:string;user:string;revision:string;side:Side;line:number;body:string;replyTo:string|null};
type Override={block:string;file:string;user:string;by:string;revision:string;reason:string};
type Requirement={path:string;owners:string[];approval:'Any'|'All';evaluation:{rule_line:number;result:{reason:string;verdict:string}}};
export type ReviewFile={id:string;name:string;directory:string;language:string;owners:string[];requirements:Requirement[];revision:string;all:boolean;rule:string;ruleLine:number;additions:number;deletions:number;original:string;modified:string;loaded:boolean;contentError?:string;change:null|{additions:number;deletions:number}};
type Event={kind:'decision'|'comment'|'override';data:Decision|Comment|Override;at:string};
type Persisted={version:number;events:Event[];draft:{decisions:Decision[];comments:Comment[]}};
type Page={draft_scope:string;csrf:string;review:{run_id:string;title:string;identity:{repository:string;pr:number;head:string};envelope:null|{report:null|{evaluation_complete:boolean;errors:{message:string}[];unowned_files:string[]}};deliveries:Record<string,{status:string}>};reviewer:{login:string;eligible_owners:string[]};files:ReviewFile[];state:Persisted;current:boolean;admin:boolean};
export let page:Page;
export const files:ReviewFile[]=[];
export const reviewers:Record<string,{initials:string;color:string;role:string}>={};
export let ownership='';
export const state={user:'',selected:'',showAll:false,tab:'review',split:false,decisions:[] as Decision[],pendingDecisions:[] as Decision[],drafts:[] as Comment[],comments:[] as Comment[],overrides:[] as Override[],revision:{} as Record<string,string>,activity:[] as {text:string;at:string}[]};
let csrf='';
let persisted:Persisted;
let queue:DraftQueue<Comment|Decision>;
let publishing=false;
let journalError='';
let journal:DraftJournal<Comment|Decision>|undefined;
function draftWritable(){if(publishing)throw new Error("Wait for review publication to finish.");}
const listeners=new Set<()=>void>();
export function subscribe(listener:()=>void){listeners.add(listener);return ()=>listeners.delete(listener);}
function notify(){for(const listener of listeners)listener();}
export function saving(){return queue?.pending.length||0;}
export function saveError(){return journalError||queue?.error?.message||'';}
export function draftStatus(id:string){const p=queue?.pending.find(p=>'item' in p.op&&p.op.item.id===id);return p?(p.error?'Not saved':'Saving…'):'Saved privately';}
function syncQueue(){if(!queue)return;try{journal?.save(queue.pending);journalError='';}catch{journalError='Browser draft recovery is unavailable. Keep this tab open until edits finish saving.';}const view=queue.view;state.drafts=view.comments as Comment[];state.pendingDecisions=view.decisions as Decision[];invalidateStatuses();notify();}
function enqueueDraft(operation:DraftOperation<Comment|Decision>){draftWritable();const start=performance.now();queue.enqueue(operation);performance.measure("ct-local-draft",{start,end:performance.now()});}
export function upsertComment(item:Comment){enqueueDraft({kind:'upsert_comment',item});}
export function deleteDraft(id:string){enqueueDraft({kind:'delete_comment',id});}
export function upsertDecision(item:Decision){enqueueDraft({kind:'upsert_decision',item});}
export function deleteDecision(id:string){enqueueDraft({kind:'delete_decision',id});}
export async function retryDrafts(){await queue.retry(queue.error?.message==='draft_conflict'?async()=>{const fresh=await api<Persisted>('/api/workspace/state?run='+encodeURIComponent(run));restore(fresh);syncQueue();return fresh;}:undefined);}

export let busy=false;
const run=new URLSearchParams(location.search).get('run')||'';
function authRedirect(url:string){
 const composing=Array.from(document.querySelectorAll<HTMLTextAreaElement>('dialog[open] textarea')).some(input=>input.value.trim().length>0);
 if(composing||journalError)throw new Error('Sign-in is required. Save or copy the open comment first, then retry. Your edits are still in this tab.');
 location.href=url;
}
async function api<T>(path:string,body?:unknown):Promise<T>{
 const response=await fetch(path,{method:body===undefined?'GET':'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:body===undefined?undefined:JSON.stringify(body)});
 if(response.status===401){authRedirect('/auth/login?next='+encodeURIComponent(location.pathname+location.search));throw new Error('Redirecting to sign in…');}
 const data=await response.json();
 if(!response.ok){if(data.error==='repository_forbidden'||data.error==='github_reconnect_required'){authRedirect('/auth/github/start?run='+encodeURIComponent(run)+'&next='+encodeURIComponent(location.pathname+location.search));throw new Error('Connecting your GitHub identity…');}throw new Error(String(data.error||'Request failed'));}
 return data as T;
}
export function owns(file:ReviewFile){return file.owners.some(o=>page.reviewer.eligible_owners.includes('@'+o));}
export async function load(){
 performance.mark('ct-bootstrap-start');
 page=await api<Page>('/api/workspace?run='+encodeURIComponent(run));csrf=page.csrf;state.user=page.reviewer.login;
 performance.mark('ct-metadata-ready');performance.measure('ct-bootstrap','ct-bootstrap-start','ct-metadata-ready');
 for(const f of page.files){const parts=f.id.split('/');const name=parts.pop()!;const extension=name.split('.').pop()||'';files.push({...f,name,directory:parts.join('/'),language:({rs:'rust',baml:'baml',md:'markdown',ts:'typescript',tsx:'typescript',js:'javascript',py:'python',json:'json'} as Record<string,string>)[extension]||'plaintext',all:f.requirements.some(r=>r.approval==='All'),rule:f.requirements.map(r=>`${r.approval}: ${r.owners.join(', ')} · ${r.evaluation.result.reason}`).join('\n'),ruleLine:f.requirements[0]?.evaluation.rule_line||0,additions:f.change?.additions||0,deletions:f.change?.deletions||0,original:'',modified:'',loaded:false});state.revision[f.id]=f.revision;for(const owner of f.owners)reviewers[owner]={initials:owner.slice(0,2).toUpperCase(),color:'#86a4dd',role:'Code owner'};}
 reviewers[state.user]??={initials:state.user.slice(0,2).toUpperCase(),color:'#dca64e',role:page.admin?'Repository admin':'Reviewer'};
 state.selected=files.find(owns)?.id||files[0]?.id||'';state.showAll=!files.some(owns);
 ownership=files.flatMap(f=>f.requirements.map(r=>`${f.id}\n  line ${r.evaluation.rule_line} · ${r.approval} of ${r.owners.join(', ')}\n  ${r.evaluation.result.reason}`)).join('\n\n');
 restore(page.state);
 queue=new DraftQueue<Comment|Decision>(page.state.draft,page.state.version,async(operation,id,version)=>{
  const started=performance.now();
  try{return await api<{version:number}>('/api/workspace',{run_id:run,head:page.review.identity.head,action:'operation',operation_id:id,expected_version:version,operation});}
  finally{performance.measure('ct-durable-draft',{start:started,end:performance.now()});}
 },syncQueue);
 journal=new DraftJournal(sessionStorage,[page.draft_scope,state.user,run,page.review.identity.head]);
 queue.pending=journal.restore();
 syncQueue();
}
function restore(data:Persisted){
 persisted=structuredClone(data);
 state.decisions=data.events.filter(e=>e.kind==='decision').map(e=>e.data as Decision);
 state.comments=[...commentPages.values()].flatMap(p=>p.items);
 state.overrides=data.events.filter(e=>e.kind==='override').map(e=>e.data as Override);
 state.pendingDecisions=data.draft.decisions;state.drafts=data.draft.comments;
 invalidateStatuses();
 state.activity=data.events.map(e=>({at:new Date(e.at).toLocaleString(),text:e.kind==='decision'?`@${(e.data as Decision).user} ${(e.data as Decision).kind==='approve'?'approved':'requested changes on'} ${(e.data as Decision).file}${(e.data as Decision).body?': '+(e.data as Decision).body:''}`:e.kind==='comment'?`@${(e.data as Comment).user} commented on ${(e.data as Comment).file}`:`Admin @${(e.data as Override).by} overrode a block: ${(e.data as Override).reason}`}));
}
async function write(action:string,body:Record<string,unknown>={}){if(busy)throw new Error('A review update is already saving.');busy=true;try{restore(await api<Persisted>('/api/workspace',{run_id:run,head:page.review.identity.head,action,...body}));}finally{busy=false;}}
export async function publish(){
 if(publishing)throw new Error('A review is already being published.');
 publishing=true;
 try{await queue.flush();await write('submit',{expected_version:queue.version});await refreshState();}
 catch(e){if(e instanceof Error&&e.message==='draft_conflict'&&!queue.error){await refreshState();throw new Error('Another tab changed this draft. Review the updated draft before submitting.');}throw e;}
 finally{publishing=false;}
}
export async function overrideBlock(block:string,reason:string){if(publishing)throw new Error('A review update is in progress.');publishing=true;try{await queue.flush();await write('override',{block,reason});await refreshState();}finally{publishing=false;}}
async function refreshState(){const fresh=await api<Persisted>('/api/workspace/state?run='+encodeURIComponent(run));restore(fresh);queue.base=fresh.draft;queue.version=fresh.version;commentPages.clear();await loadComments(state.selected);notify();}
const contents=new Map<string,Promise<void>>();
const contentLRU=new Map<string,ReviewFile>();
const contentSize=()=>[...contentLRU.values()].reduce((n,f)=>n+2*(f.original.length+f.modified.length),0);
let fetching=0;
const slots:(()=>void)[]=[];
async function slot(){if(fetching>=2)await new Promise<void>(resolve=>slots.push(resolve));else fetching++;return ()=>{const next=slots.shift();if(next)next();else fetching--;};}
export async function loadContent(file:ReviewFile):Promise<void>{
 if(file.loaded){contentLRU.delete(file.id);contentLRU.set(file.id,file);return;}
 const existing=contents.get(file.id);if(existing)return existing;
 const work=(async()=>{const release=await slot();const start=performance.now();
 try{const data=await api<{original:string;modified:string}>('/api/workspace/content?run='+encodeURIComponent(run)+'&file='+encodeURIComponent(file.id));file.original=data.original;file.modified=data.modified;file.loaded=true;file.contentError=undefined;contentLRU.set(file.id,file);
  for(const [id,cached] of contentLRU){if(contentLRU.size<=12&&contentSize()<=8*1024*1024)break;if(id===state.selected||id===file.id)continue;cached.original='';cached.modified='';cached.loaded=false;contentLRU.delete(id);}
 }catch(e){file.contentError=e instanceof Error?e.message:String(e);}
 finally{release();contents.delete(file.id);performance.measure('ct-content',{start,end:performance.now()});}
 })();contents.set(file.id,work);return work;
}
export function prefetchNext(file:ReviewFile){const assigned=files.filter(owns);const next=assigned[assigned.indexOf(file)+1];if(next&&next.id!==file.id&&!next.loaded&&contentSize()<6*1024*1024)void loadContent(next);}
const commentPages=new Map<string,{loaded:boolean;more:boolean;cursor:number;items:Comment[];loading?:Promise<void>;error?:string}>();
export function commentsFor(file:string){return commentPages.get(file)?.items||[];}
export function commentsInfo(file:string){return commentPages.get(file);}
export async function loadComments(file:string,more=false):Promise<void>{
 let entry=commentPages.get(file);if(!entry){entry={loaded:false,more:false,cursor:0,items:[]};commentPages.set(file,entry);}
 commentPages.delete(file);commentPages.set(file,entry);
 // Keep at most twelve inactive file histories; in-flight and selected files stay alive.
 for(const [id,cached] of commentPages){if(commentPages.size<=12)break;if(id!==file&&id!==state.selected&&!cached.loading)commentPages.delete(id);}
 if(entry.loading)return entry.loading;if(entry.loaded&&!more)return;
 const current=entry;current.error=undefined;const started=performance.now();
 const work=(async()=>{try{const data=await api<{events:Event[];cursor:number;more:boolean}>('/api/workspace/comments?run='+encodeURIComponent(run)+'&file='+encodeURIComponent(file)+'&after='+current.cursor);current.items.push(...data.events.map(e=>e.data as Comment));current.cursor=data.cursor;current.more=data.more;current.loaded=true;state.comments=[...commentPages.values()].flatMap(p=>p.items);performance.mark('ct-comments-ready');}
 catch(e){current.error=e instanceof Error?e.message:String(e);}finally{current.loading=undefined;if(state.selected===file)notify();performance.measure('ct-comments',{start:started,end:performance.now()});}})();current.loading=work;return work;
}
const statusCache=new Map<string,ReturnType<typeof computeStatus>>();
function invalidateStatuses(){statusCache.clear();}
export function fileStatus(file:ReviewFile,s=state){if(s!==state)return computeStatus(file,s);let status=statusCache.get(file.id);if(!status){status=computeStatus(file,s);statusCache.set(file.id,status);}return status;}
function computeStatus(file:ReviewFile,s=state){
 const latest=[...new Map(s.decisions.filter(v=>v.file===file.id).map(v=>[v.user,v])).values()];
 const activeBlocks=latest.filter(v=>v.kind==='changes'&&!s.overrides.some(o=>o.block===v.id));
 const approvals=new Set(latest.filter(v=>v.revision===s.revision[file.id]&&v.kind==='approve').flatMap(v=>v.owners||[v.user]));
 const approved=file.requirements.length>0&&file.requirements.every(r=>r.approval==='All'?r.owners.every(o=>approvals.has(o.slice(1).toLowerCase())):r.owners.some(o=>approvals.has(o.slice(1).toLowerCase())));
 return {state:activeBlocks.length?'blocked':approved?'approved':file.owners.length?'pending':'unowned',activeBlocks,approvals};
}
