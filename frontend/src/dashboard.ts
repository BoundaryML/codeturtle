import './dashboard.css';
type Identity = {repository_id:string;repository:string;pr:number;head:string;base:string;policy:string;run_id:string;run_attempt:number};
type Requirement = {path:string;owners:string[];approval:'Any'|'All';evaluation:{result:{verdict:string;reason:string;evidence:string[]}}};
type Review = {run_id:string;identity:Identity;title:string;accepted_at:string|null;superseded:boolean;status:string;envelope:null|{setup_failure:null|{message:string};report:null|{requirements:Requirement[];errors:{message:string}[];unowned_files:string[];evaluation_complete:boolean}};deliveries:Record<string,{status:string;error:string|null}>};
type Session={csrf:string;repositories:{id:string;name:string;can_setup:boolean;latest_run:string|null}[]};
const app=document.querySelector<HTMLElement>('#app')!;
let csrf='';
export class SignInRequired extends Error {}
function el<K extends keyof HTMLElementTagNameMap>(tag:K,text='',className=''):HTMLElementTagNameMap[K]{const e=document.createElement(tag);e.textContent=text;e.className=className;return e;}
function link(text:string,href:string){const a=el('a',text);a.href=href;return a;}
async function api<T>(path:string,body?:unknown):Promise<T>{const r=await fetch(path,{method:body===undefined?'GET':'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:body===undefined?undefined:JSON.stringify(body)});if(r.status===401){app.replaceChildren(el('h1','Sign in to CodeTurtle'),link('Continue with WorkOS','/auth/login?next='+encodeURIComponent(location.pathname+location.search)));throw new SignInRequired('Sign in required');}if(!r.ok){const data=await r.json();throw new Error(String(data.error??'Request failed'));}return r.json() as Promise<T>;}
function error(e:unknown){if(e instanceof SignInRequired)return;app.append(el('p',e instanceof Error?e.message:'Request failed','error'));}
function input(label:string,placeholder:string){const l=el('label',label);const i=el('input');i.placeholder=placeholder;l.append(i);return {label:l,input:i};}
function button(text:string,action:()=>Promise<void>){const b=el('button',text);b.onclick=()=>{b.disabled=true;void action().catch(error).finally(()=>b.disabled=false);};return b;}
async function setup(repository:string){const panel=el('section');panel.append(el('h2','Connect repository'));const state=await api<{stage:string;pr?:{url:string}}>('/api/setup?repository_id='+encodeURIComponent(repository));panel.append(el('p',state.stage.replaceAll('_',' ')));if(state.pr)panel.append(link('View setup PR',state.pr.url));const owners=input('Confirmed GitHub owners','@owner @organization/team');panel.append(owners.label);let preview:unknown=null;panel.append(button('Preview workflow and policy',async()=>{preview=await api('/api/setup',{repository_id:repository,options:{owners:owners.input.value.trim().split(/\s+/),create_pr:false}});panel.append(el('pre',JSON.stringify(preview,null,2)));panel.append(button('Create setup PR',async()=>{await api('/api/setup',{repository_id:repository,options:{owners:owners.input.value.trim().split(/\s+/),create_pr:true}});location.reload();}));}));panel.append(link('Connect Slack workspace','/auth/slack/start?repository_id='+encodeURIComponent(repository)));const channel=input('Slack channel ID','C0123456789'),owner=input('GitHub owner','@owner'),user=input('Verified Slack member ID','U0123456789');panel.append(channel.label,owner.label,user.label,button('Save owner mapping',async()=>{await api('/api/slack/mapping',{repository_id:repository,channel:channel.input.value,owner:owner.input.value,user_id:user.input.value});panel.append(el('p','Mapping saved.'));}));app.append(panel);}
export async function dashboard(){app.classList.add('dashboard');const session=await api<Session>('/api/session');csrf=session.csrf;const q=new URLSearchParams(location.search),run=q.get('run');app.replaceChildren(el('h1','Your repositories'));for(const repo of session.repositories){const section=el('section');section.append(el('h2',repo.name));if(repo.latest_run)section.append(link('Latest report','/?run='+encodeURIComponent(repo.latest_run)));if(repo.can_setup)section.append(link('Repository setup','/?repository='+encodeURIComponent(repo.id)));app.append(section);}const selected=q.get('repository');if(selected)await setup(selected);await repositoryPicker(q.get('connect')==='github');}

async function repositoryPicker(connected:boolean){
  const panel=el('section');
  panel.append(el('h2','Connect a repository'));
  const install=link('Manage GitHub App access','https://github.com/apps/codeturtle-app/installations/new');
  install.target='_blank';install.rel='noopener noreferrer';
  panel.append(install);
  app.append(panel);
  if(!connected){
    panel.append(el('p','Connect GitHub to choose a repository you administer.'),link('Connect GitHub','/auth/github/start'));
    return;
  }
  const status=el('p','Loading repositories…');panel.append(status);
  try{
    const data=await api<{repositories:{id:string;name:string}[]}>('/api/github/repositories');
    status.textContent=data.repositories.length?'Choose a repository to set up CodeTurtle.':'No available repositories. Give the GitHub App access to a repository you administer, then refresh.';
    if(data.repositories.length){
      const label=el('label','Repository'),select=el('select');
      for(const repo of data.repositories.sort((a,b)=>a.name.localeCompare(b.name))){const option=el('option',repo.name);option.value=repo.id;select.append(option);}
      label.append(select);panel.append(label,button('Continue to setup',async()=>{
        const linked=await api<{repository_id:string}>('/api/github/repositories',{repository_id:select.value});
        location.href='/?repository='+encodeURIComponent(linked.repository_id);
      }));
    }
    panel.append(button('Refresh repositories',async()=>{panel.remove();await repositoryPicker(true);}));
  }catch(e){
    if(e instanceof SignInRequired)throw e;
    status.textContent=e instanceof Error&&['github_connect_required','github_reconnect_required'].includes(e.message)?'Connect GitHub again to load your repositories.':'Could not load repositories. Try connecting GitHub again.';
    panel.append(link('Connect GitHub','/auth/github/start'));
  }
}
