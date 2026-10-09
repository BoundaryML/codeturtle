import '@fontsource/geist/latin-400.css';
import '@fontsource/geist/latin-600.css';
import './style.css';
import {dashboard, SignInRequired} from './dashboard';
performance.mark('ct-navigation');
const start = new URLSearchParams(location.search).has('run')
  ? import('./review').then(review => review.start())
  : dashboard();
void start.catch(error => {
 if(error instanceof SignInRequired)return;
 const app=document.querySelector<HTMLElement>('#app')!;
 const message=document.createElement('p');message.textContent=error instanceof Error?error.message:String(error);
 const link=document.createElement('a');link.href='/';link.textContent='Back to repositories';
 app.replaceChildren(message,link);
});
