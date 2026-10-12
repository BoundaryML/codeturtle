import * as monaco from 'monaco-editor/editor/editor.api';
import 'monaco-editor/languages/definitions/rust/register';
import 'monaco-editor/languages/definitions/markdown/register';
import EditorWorker from 'monaco-editor/editor/editor.worker?worker';
import '../node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon.css';
import type {ReviewFile,Comment,Side} from './workspace';
monaco.languages.register({ id: 'baml' });
monaco.languages.setMonarchTokensProvider('baml', { tokenizer: { root: [[/\b(class|enum|function|client|test|retry_policy)\b/, 'keyword'], [/\b(string|int|float|bool)\b/, 'type'], [/"[^"\\]*(?:\\.[^"\\]*)*"/, 'string'], [/\/\/.*$/, 'comment'], [/\b\d+\b/, 'number'], [/@[\w]+/, 'annotation']] } });
monaco.editor.defineTheme('codeturtle', {
  base: 'vs-dark', inherit: true,
  rules: [{ token: 'comment', foreground: '7D8594' }, { token: 'keyword', foreground: 'C8BAFF' }, { token: 'string', foreground: '91D8C0' }, { token: 'number', foreground: 'E4B77B' }, { token: 'type', foreground: '8DB8CF' }],
  colors: { 'editor.background': '#18171a', 'editorGutter.background': '#18171a', 'editorLineNumber.foreground': '#5f6777', 'editorLineNumber.activeForeground': '#d0d0d7', 'editor.lineHighlightBackground': '#232225', 'diffEditor.insertedTextBackground': '#73be8528', 'diffEditor.removedTextBackground': '#da777c25', 'diffEditor.insertedLineBackground': '#51835c12', 'diffEditor.removedLineBackground': '#b7585f12', 'editor.selectionBackground': '#ff570a30', 'editorWidget.background': '#232225', 'editorOverviewRuler.border': '#2b292d' },
});

let diffEditor:monaco.editor.IStandaloneDiffEditor|undefined;
let currentSplit:boolean|undefined;
let currentKey='';
let editorCreations=0;
let modelCreations=0;
let callback:(line:number,side:Side)=>void;
let currentFile:ReviewFile|undefined;
let originalDecorations:monaco.editor.IEditorDecorationsCollection|undefined;
let modifiedDecorations:monaco.editor.IEditorDecorationsCollection|undefined;
type Models={diff:monaco.editor.IDiffEditorViewModel;original:monaco.editor.ITextModel;modified:monaco.editor.ITextModel;view:monaco.editor.IDiffEditorViewState|null;bytes:number};
const models=new Map<string,Models>();
const workers:Worker[]=[];
(self as unknown as {MonacoEnvironment:{getWorker:()=>Worker}}).MonacoEnvironment={getWorker:()=>{const worker=new EditorWorker();workers.push(worker);return worker;}};
function trim(){let bytes=[...models.values()].reduce((n,m)=>n+m.bytes,0);for(const [key,m] of models){if(models.size<=12&&bytes<=12*1024*1024)break;if(key===currentKey)continue;m.diff.dispose();m.original.dispose();m.modified.dispose();models.delete(key);bytes-=m.bytes;}}
export function line(){return diffEditor?.getModifiedEditor().getPosition()?.lineNumber||1;}
export function show(container:HTMLElement,file:ReviewFile,split:boolean,comments:Comment[],drafts:Comment[],onComment:(line:number,side:Side)=>void){
 callback=onComment;currentFile=file;container.setAttribute("aria-label","Diff for "+file.name);
 if(!diffEditor){
  container.replaceChildren();performance.mark('ct-editor-create');editorCreations++;
  diffEditor=monaco.editor.createDiffEditor(container,{theme:'codeturtle',readOnly:true,originalEditable:false,renderSideBySide:split,automaticLayout:true,minimap:{enabled:false},fontSize:13,lineHeight:22,fontFamily:'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',scrollBeyondLastLine:false,glyphMargin:true,renderOverviewRuler:false,diffCodeLens:false,wordWrap:'off',stickyScroll:{enabled:false},accessibilitySupport:'auto',padding:{top:16,bottom:16},hideUnchangedRegions:{enabled:true,contextLineCount:5,minimumLineCount:10,revealLineCount:20},maxComputationTime:1500,maxFileSize:2});
  for(const [editor,side] of [[diffEditor.getOriginalEditor(),'LEFT'],[diffEditor.getModifiedEditor(),'RIGHT']] as const){
   editor.addAction({id:`codeturtle-comment-${side}`,label:'Draft a CodeTurtle comment',contextMenuGroupId:'navigation',run:()=>callback(editor.getPosition()?.lineNumber||1,side)});
   editor.onMouseDown(event=>{if(currentFile?.loaded&&event.target.type===monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN&&event.target.position)callback(event.target.position.lineNumber,side);});
  }
  originalDecorations=diffEditor.getOriginalEditor().createDecorationsCollection();modifiedDecorations=diffEditor.getModifiedEditor().createDecorationsCollection();
  diffEditor.onDidUpdateDiff(()=>{performance.mark('ct-diff-ready');requestAnimationFrame(()=>performance.mark('ct-diff-painted'));});
 }
 const key=file.id+':'+file.revision+(file.loaded?'':':loading:'+(file.contentError||''));
 if(currentSplit!==split){diffEditor.updateOptions({renderSideBySide:split});currentSplit=split;}
 if(key!==currentKey){
  const old=models.get(currentKey);if(old)old.view=diffEditor.saveViewState();
  currentKey=key;
  let pair=models.get(key);
  if(!pair){
   modelCreations+=2;
   const original=monaco.editor.createModel(file.loaded?file.original:'',file.language);
   const modified=monaco.editor.createModel(file.loaded?file.modified:file.contentError?'Diff unavailable. Use Open on GitHub.':'Loading diff…',file.language);
   pair={original,modified,diff:diffEditor.createViewModel({original,modified}),view:null,bytes:2*(file.original.length+file.modified.length)};
   models.set(key,pair);
  }
  else {models.delete(key);models.set(key,pair);}
  container.removeAttribute('data-limited');performance.mark('ct-model-attach');
  diffEditor.setModel(pair.diff);
  if(file.loaded){const attached=performance.now();void pair.diff.waitForDiff().then(()=>{if(currentKey!==key)return;requestAnimationFrame(()=>{if(currentKey!==key)return;performance.measure('ct-diff-paint',{start:attached,end:performance.now()});if(!performance.getEntriesByName('ct-first-diff','measure').length)performance.measure('ct-first-diff','ct-navigation');});}).catch(()=>{});}
  if(pair.view)diffEditor.restoreViewState(pair.view);trim();
 }
 for(const [collection,side] of [[originalDecorations,'LEFT'],[modifiedDecorations,'RIGHT']] as const){collection?.set([...comments,...drafts].filter(c=>c.file===file.id&&c.side===side&&c.revision===file.revision).map(c=>({range:new monaco.Range(c.line,1,c.line,1),options:{isWholeLine:true,className:'codeturtle-comment-line',glyphMarginClassName:'codeturtle-comment-glyph',glyphMarginHoverMessage:{value:`CodeTurtle comment by @${c.user}`}}})));}

}
export function dispose(){diffEditor?.dispose();diffEditor=undefined;for(const m of models.values()){m.diff.dispose();m.original.dispose();m.modified.dispose();}models.clear();for(const w of workers)w.terminate();workers.length=0;currentKey='';currentSplit=undefined;}

export function stats(){return {editorCreations,modelCreations,retainedModels:models.size*2,modelBytes:[...models.values()].reduce((n,m)=>n+m.bytes,0)};}
