type Identity = {repository_id:string;repository:string;pr:number;head:string;base:string;policy:string;run_id:string;run_attempt:number};
type Requirement = {path:string;owners:string[];approval:'Any'|'All';evaluation:{result:{verdict:string;reason:string;evidence:string[]}}};
type Review = {run_id:string;identity:Identity;title:string;accepted_at:string|null;superseded:boolean;status:string;envelope:null|{setup_failure:null|{message:string};report:null|{requirements:Requirement[];errors:{message:string}[];unowned_files:string[];evaluation_complete:boolean}};deliveries:Record<string,{status:string;error:string|null}>};
type Session={csrf:string;repositories:{id:string;name:string;can_setup:boolean;latest_run:string|null}[]};
const app=document.querySelector<HTMLElement>('#app')!;
let csrf='';
function el<K extends keyof HTMLElementTagNameMap>(tag:K,text='',className=''):HTMLElementTagNameMap[K]{const e=document.createElement(tag);e.textContent=text;e.className=className;return e;}
function link(text:string,href:string){const a=el('a',text);a.href=href;return a;}
async function api<T>(path:string,body?:unknown):Promise<T>{const r=await fetch(path,{method:body===undefined?'GET':'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:body===undefined?undefined:JSON.stringify(body)});if(r.status===401){app.replaceChildren(el('h1','Sign in to CodeTurtle'),link('Continue with WorkOS','/auth/login?next='+encodeURIComponent(location.pathname+location.search)));throw new Error('Sign in required');}if(!r.ok){const data=await r.json();throw new Error(String(data.error??'Request failed'));}return r.json() as Promise<T>;}
function error(e:unknown){app.append(el('p',e instanceof Error?e.message:'Request failed','error'));}
type Decision = {requirement_index:number;owner:string;github_user_id:string;github_login:string;reviewed_at:string};
type ReviewerRow = {owner:string;parts:string[];indices:number[];completed:number;url:string};
type ReviewPage = {review:Review;reviewer:{user_id:string;login:string;eligible_owners:string[]};decisions:Decision[];reviewers:ReviewerRow[];current:boolean;completed_requirements:number;total_requirements:number};
async function load_review(run:string) {
  try { render_review(await api<ReviewPage>('/api/review?run='+encodeURIComponent(run))); }
  catch(e) {
    if(e instanceof Error && e.message==='repository_forbidden') {
      app.replaceChildren(el('h1','Connect your GitHub identity'),el('p','Verify your repository access to open this review.'));
      app.append(link('Continue with GitHub','/auth/github/start?run='+encodeURIComponent(run)+'&next='+encodeURIComponent(location.pathname+location.search)));
    } else { throw e; }
  }
}
function render_review(page:ReviewPage) {
  const view=page.review, report=view.envelope?.report;
  const selected=new URLSearchParams(location.search).get('reviewer')?.toLowerCase();
  const own=page.reviewer.eligible_owners;
  app.replaceChildren(link('← Repositories','/'),el('h1',view.title));
  app.append(link(`${view.identity.repository} #${view.identity.pr}`,`https://github.com/${view.identity.repository}/pull/${view.identity.pr}`));
  app.append(el('p',`Signed in as @${page.reviewer.login} · Reviewing commit ${view.identity.head.slice(0,12)}`));
  if(view.superseded || !page.current) app.append(el('p','This report is no longer current or its revision could not be verified. Sign-offs are disabled. Open the latest CodeTurtle comment on the PR.','notice'));
  const summary=el('section');summary.append(el('h2','Review progress'),el('p',`${page.completed_requirements} of ${page.total_requirements} requirements reviewed`));
  summary.append(el('p',report?.evaluation_complete?'Automated evaluation complete. Human sign-offs are tracked separately.':'Evaluation is incomplete. Review sign-offs do not resolve evaluation errors or ownership gaps.'));
  const table=el('table'),head=el('tr');for(const title of ['Reviewer','Parts','Progress','Review'])head.append(el('th',title));
  const thead=el('thead');thead.append(head);table.append(thead);const tbody=el('tbody');
  for(const row of page.reviewers){const tr=el('tr');tr.append(el('td',row.owner),el('td',row.parts.join(', ')),el('td',`${row.completed}/${row.indices.length}`));const td=el('td');td.append(link('Open assigned review',row.url));tr.append(td);tbody.append(tr);}table.append(tbody);summary.append(table);app.append(summary);
  if(!report){if(view.envelope?.setup_failure)app.append(el('p',view.envelope.setup_failure.message,'error'));return;}
  for(const e of report.errors)app.append(el('p',e.message,'error'));
  if(report.unowned_files.length)app.append(el('p','Unowned parts: '+report.unowned_files.join(', '),'notice'));
  const filtered=report.requirements.map((r,index)=>({r,index})).filter(({r})=>r.owners.some(o=>selected?o.toLowerCase()===selected:own.includes(o.toLowerCase())));
  app.append(el('h2',selected?`Assigned to ${selected}`:'Your assigned parts'));
  if(selected && !own.includes(selected))app.append(el('p','You can view these assignments, but only an assigned reviewer can mark them reviewed.','notice'));
  if(!filtered.length)app.append(el('p','No parts are assigned to this reviewer.'));
  const actionable=filtered.filter(({r})=>(!selected || own.includes(selected)) && r.owners.some(o=>own.includes(o.toLowerCase()))).map(x=>x.index);
  const save=async(indices:number[],reviewed:boolean)=>{await api('/api/review/decision',{run_id:view.run_id,head:view.identity.head,indices,reviewed});await load_review(view.run_id);};
  if(actionable.length && page.current && !view.superseded)app.append(button('Mark all my assigned parts reviewed',()=>save(actionable,true)));
  for(const {r,index} of filtered) {
    const card=el('article');card.append(el('h2',r.path),el('p',`${r.approval==='All'?'All of':'Any of'} ${r.owners.join(', ')}`),el('p',r.evaluation.result.reason));
    if(r.evaluation.result.verdict==='Uncertain')card.append(el('p','Uncertain — human review required.','notice'));
    for(const evidence of r.evaluation.result.evidence)card.append(el('pre',evidence));
    card.append(link('Open PR files on GitHub',`https://github.com/${view.identity.repository}/pull/${view.identity.pr}/files`));
    const diff=el('div');card.append(button('Show diff',async()=>{const data=await api<{patch:string|null;message:string}>('/api/review/diff?run='+encodeURIComponent(view.run_id)+'&index='+index);diff.replaceChildren(data.patch?el('pre',data.patch):el('p',data.message));}),diff);
    const decisions=page.decisions.filter(d=>d.requirement_index===index);
    for(const d of decisions)card.append(el('p',`Reviewed by @${d.github_login} for ${d.owner} · ${new Date(d.reviewed_at).toLocaleString()}`,'reviewed'));
    const mine=decisions.some(d=>d.github_user_id===page.reviewer.user_id);
    if(actionable.includes(index) && page.current && !view.superseded)card.append(button(mine?'Reopen my review':'Mark reviewed',()=>save([index],!mine)));
    app.append(card);
  }
  if(selected)app.append(link('Show my assignments','/?run='+encodeURIComponent(view.run_id)));
  const delivery=el('section');delivery.append(el('h2','Publication status'));for(const [provider,status] of Object.entries(view.deliveries))delivery.append(el('p',`${provider}: ${status.status}${status.error?' — '+status.error:''}`));app.append(delivery);
}
function input(label:string,placeholder:string){const l=el('label',label);const i=el('input');i.placeholder=placeholder;l.append(i);return {label:l,input:i};}
function button(text:string,action:()=>Promise<void>){const b=el('button',text);b.onclick=()=>{b.disabled=true;void action().catch(error).finally(()=>b.disabled=false);};return b;}
async function setup(repository:string){const panel=el('section');panel.append(el('h2','Connect repository'));const state=await api<{stage:string;pr?:{url:string}}>('/api/setup?repository_id='+encodeURIComponent(repository));panel.append(el('p',state.stage.replaceAll('_',' ')));if(state.pr)panel.append(link('View setup PR',state.pr.url));const owners=input('Confirmed GitHub owners','@owner @organization/team');panel.append(owners.label);let preview:unknown=null;panel.append(button('Preview workflow and policy',async()=>{preview=await api('/api/setup',{repository_id:repository,options:{owners:owners.input.value.trim().split(/\s+/),create_pr:false}});panel.append(el('pre',JSON.stringify(preview,null,2)));panel.append(button('Create setup PR',async()=>{await api('/api/setup',{repository_id:repository,options:{owners:owners.input.value.trim().split(/\s+/),create_pr:true}});location.reload();}));}));panel.append(link('Connect Slack workspace','/auth/slack/start?repository_id='+encodeURIComponent(repository)));const channel=input('Slack channel ID','C0123456789'),owner=input('GitHub owner','@owner'),user=input('Verified Slack member ID','U0123456789');panel.append(channel.label,owner.label,user.label,button('Save owner mapping',async()=>{await api('/api/slack/mapping',{repository_id:repository,channel:channel.input.value,owner:owner.input.value,user_id:user.input.value});panel.append(el('p','Mapping saved.'));}));app.append(panel);}
async function main(){const session=await api<Session>('/api/session');csrf=session.csrf;const q=new URLSearchParams(location.search),run=q.get('run');if(run){await load_review(run);return;}app.replaceChildren(el('h1','Your repositories'));for(const repo of session.repositories){const section=el('section');section.append(el('h2',repo.name));if(repo.latest_run)section.append(link('Latest report','/?run='+encodeURIComponent(repo.latest_run)));if(repo.can_setup)section.append(link('Repository setup','/?repository='+encodeURIComponent(repo.id)));app.append(section);}const selected=q.get('repository');if(selected)await setup(selected);const connect=el('section');connect.append(el('h2','Link a GitHub App installation'),el('p','Install the CodeTurtle GitHub App on selected repositories, then verify your administrator access here.'));const install=input('Installation ID','123456'),repository=input('Repository ID','123456');connect.append(install.label,repository.label,button('Verify with GitHub',async()=>{location.href='/auth/github/start?installation_id='+encodeURIComponent(install.input.value)+'&repository_id='+encodeURIComponent(repository.input.value);}));app.append(connect);}
void main().catch(error);
