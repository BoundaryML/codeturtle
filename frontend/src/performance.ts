// Opt-in local diagnostics. No telemetry is transmitted and no source/comment text is recorded.
export function diagnostics(editorStats:()=>Record<string,number>){
 if(!new URLSearchParams(location.search).has('performance'))return;
 const panel=document.createElement('details');panel.id='performance-diagnostics';panel.style.cssText='position:fixed;right:8px;bottom:8px;z-index:25;background:#18171a;padding:8px;max-height:45vh;overflow:auto';
 const summary=document.createElement('summary');summary.textContent='Performance diagnostics';
 const output=document.createElement('pre');panel.append(summary,output);document.body.append(panel);
 const render=()=>{
  const names=['ct-shell','ct-bootstrap','ct-file-switch','ct-content','ct-comments','ct-local-draft','ct-durable-draft','ct-diff-paint','ct-first-diff','ct-long-task'];
  const results=Object.fromEntries(names.map(name=>{const entries=performance.getEntriesByName(name,'measure').slice(-100);const values=entries.map(e=>e.duration).sort((a,b)=>a-b);return [name,{n:values.length,last:Math.round(entries.at(-1)?.duration||0),p95:Math.round(values[Math.max(0,Math.ceil(values.length*.95)-1)]||0)}];}));
  output.textContent=JSON.stringify({...results,...editorStats()},null,2);
 };
 const observer=PerformanceObserver.supportedEntryTypes.includes('longtask')?new PerformanceObserver(list=>{for(const e of list.getEntries())performance.measure('ct-long-task',{start:e.startTime,duration:e.duration});}):undefined;
 observer?.observe({type:'longtask',buffered:true});
 const timer=setInterval(render,500);window.addEventListener('pagehide',()=>{clearInterval(timer);observer?.disconnect();},{once:true});
}
