import '@fontsource/geist/latin-400.css';
import '@fontsource/geist/latin-600.css';
import 'hack-font/build/web/hack.css';
import * as monaco from 'monaco-editor/editor/editor.api';
import 'monaco-editor/languages/definitions/rust/register';
import 'monaco-editor/languages/definitions/markdown/register';
import EditorWorker from 'monaco-editor/editor/editor.worker?worker';
import '../node_modules/monaco-editor/esm/vs/base/browser/ui/codicons/codicon/codicon.css';
import { files, reviewers, ownership, state, page, load, saveDrafts, publish, overrideBlock, loadContent, fileStatus, owns, busy, type ReviewFile, type Decision, type Comment, type Side } from './workspace';
import { dashboard, SignInRequired } from './dashboard';
import './style.css';

(self as unknown as { MonacoEnvironment: { getWorker: () => Worker } }).MonacoEnvironment = { getWorker: () => new EditorWorker() };
monaco.languages.register({ id: 'baml' });
monaco.languages.setMonarchTokensProvider('baml', { tokenizer: { root: [[/\b(class|enum|function|client|test|retry_policy)\b/, 'keyword'], [/\b(string|int|float|bool)\b/, 'type'], [/"[^"\\]*(?:\\.[^"\\]*)*"/, 'string'], [/\/\/.*$/, 'comment'], [/\b\d+\b/, 'number'], [/@[\w]+/, 'annotation']] } });
monaco.editor.defineTheme('codeturtle', {
  base: 'vs-dark', inherit: true,
  rules: [{ token: 'comment', foreground: '7D8594' }, { token: 'keyword', foreground: 'C8BAFF' }, { token: 'string', foreground: '91D8C0' }, { token: 'number', foreground: 'E4B77B' }, { token: 'type', foreground: '8DB8CF' }],
  colors: { 'editor.background': '#18171a', 'editorGutter.background': '#18171a', 'editorLineNumber.foreground': '#5f6777', 'editorLineNumber.activeForeground': '#d0d0d7', 'editor.lineHighlightBackground': '#232225', 'diffEditor.insertedTextBackground': '#73be8528', 'diffEditor.removedTextBackground': '#da777c25', 'diffEditor.insertedLineBackground': '#51835c12', 'diffEditor.removedLineBackground': '#b7585f12', 'editor.selectionBackground': '#ff570a30', 'editorWidget.background': '#232225', 'editorOverviewRuler.border': '#2b292d' },
});

const escape = (value: unknown): string => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' } as Record<string,string>)[char]!);

let diffEditor: monaco.editor.IStandaloneDiffEditor | undefined, models: monaco.editor.ITextModel[] = [];
const app = document.querySelector<HTMLElement>('#app')!;
const selected = () => files.find(file => file.id === state.selected)!;
const mine = () => files.filter(file => owns(file));
const myDrafts = () => state.drafts.filter(draft => draft.user === state.user);
const myPendingDecisions = () => state.pendingDecisions.filter(decision => decision.user === state.user);
const currentDecision = (file: ReviewFile) => { const latest=[...state.decisions].reverse().find(decision => decision.file === file.id && decision.user === state.user); return latest?.revision===state.revision[file.id]?latest:undefined; };
const stagedDecision = (file: ReviewFile) => myPendingDecisions().find(decision => decision.file === file.id && decision.revision === state.revision[file.id]);
const myDecision = (file: ReviewFile) => stagedDecision(file) || currentDecision(file);
const undecidedFiles = () => mine().filter(file => !myDecision(file));
function personalStatus(file: ReviewFile) {
  const decision = myDecision(file);
  return { state: decision?.kind === 'approve' ? 'approved' : decision?.kind === 'changes' ? 'blocked' : 'pending', label: decision ? `${decision.kind === 'approve' ? 'Approved' : 'Rejected'}${stagedDecision(file) ? ' · draft' : ''}` : 'Not reviewed' };
}


const statusLabel: Record<string,string> = { pending: 'Awaiting sign-off', approved: 'Approved', blocked: 'Changes requested', unowned: 'No owner assigned' };

function avatar(user: string, small = false) {
  const info = reviewers[user];
  return `<span class="avatar ${small ? 'small' : ''}" style="--avatar-color:${info?.color || '#8191aa'}" aria-hidden="true">${info?.initials || 'S'}</span>`;
}

function summary() {
  const owned = files.filter(file => file.owners.length);
  const approved = owned.filter(file => fileStatus(file, state).state === 'approved').length;
  const blocked = owned.filter(file => fileStatus(file, state).state === 'blocked').length;
  return { owned, approved, blocked, ready: owned.length > 0 && approved === owned.length && !blocked && page.review.envelope?.report?.evaluation_complete === true };
}

function reviewerProgress(user: string) {
  const owned = files.filter(file => file.owners.includes(user));
  const approved = owned.filter(file => fileStatus(file, state).approvals.has(user)).length;
  return `${approved}/${owned.length}`;
}

function header() {
 return `<header class="appbar"><div class="brand"><a href="/"><img class="brand-logo" src="/codeturtle.svg" alt="Repositories" /></a><span class="brand-wordmark">codeturtle<span class="brand-tagline">slow down and read the code</span></span><span class="repo-name">${escape(page.review.identity.repository)}</span></div><nav aria-label="Workspace">${[['review','Review'],['github','PR message'],['slack','Slack'],['ownership','Ownership']].map(([tab,label])=>`<button data-tab="${tab}" class="${state.tab===tab?'active':''}">${label}</button>`).join('')}</nav><span class="identity">${avatar(state.user,true)}@${escape(state.user)}</span></header><section class="prbar"><div class="pr-title"><div class="pr-kicker"><span class="codicon codicon-git-pull-request"></span><a href="https://github.com/${escape(page.review.identity.repository)}/pull/${page.review.identity.pr}">Pull request #${page.review.identity.pr}</a></div><h1>${escape(page.review.title)}</h1><div class="prmeta"><code>${page.review.identity.head.slice(0,12)}</code><span>· ${files.length} files changed</span>${page.review.envelope?.report?.errors.map(e=>`<span class="blocked">${escape(e.message)}</span>`).join('') || ''}${page.review.envelope?.report?.unowned_files.length?'<span class="blocked">Ownership gaps need attention</span>':''}${!page.current?'<span class="blocked">Outdated report · open the latest PR comment</span>':''}</div></div></section>`;
}

function fileTree() {
  const visible = state.showAll ? files : mine();
  return `<aside class="filetree"><div class="section-label">${state.showAll ? 'Changed files' : 'Your files'} <span>${visible.length}</span></div><div class="tree-filter"><span class="codicon codicon-filter" aria-hidden="true"></span>${state.showAll ? 'All changed files' : `Owned by @${escape(state.user)}`}</div><div class="filelist">${visible.map(file => {
    const status = owns(file) ? personalStatus(file) : { ...fileStatus(file, state), label: statusLabel[fileStatus(file, state).state] };
    const shortPath = file.directory.includes('baml_env') ? 'crates / baml_env / src' : file.directory.includes('baml_std') ? 'baml_std / baml / ns_http' : file.directory === 'baml_language' ? 'baml_language' : file.directory;
    return `<div class="file-group"><div class="file-directory" title="${escape(file.directory)}">${escape(shortPath)}</div><button class="file ${state.selected === file.id ? 'selected' : ''}" data-file="${escape(file.id)}" title="${escape(file.directory + '/' + file.name)}"><span class="codicon codicon-file-code" aria-hidden="true"></span><strong>${escape(file.name)}</strong><span class="file-dot ${status.state}" role="img" aria-label="${status.label}"></span></button></div>`;
  }).join('')}</div><button class="reveal-files" data-action="show-all"><span class="codicon codicon-${state.showAll ? 'eye-closed' : 'eye'}" aria-hidden="true"></span>${state.showAll ? 'Hide other files' : `Show ${files.length - mine().length} other ${files.length - mine().length === 1 ? 'file' : 'files'}`}</button><div class="tree-foot"><button data-tab="ownership"><span class="codicon codicon-symbol-key" aria-hidden="true"></span> CODETURTLE.md (or legacy OWNERS)</button><span>Rules from the target branch</span></div></aside>`;
}

function commentCard(comment: Comment, draft = false) {
  const outdated = comment.revision !== state.revision[comment.file];
  return `<article class="comment-card ${draft ? 'draft' : ''}"><div class="comment-meta">${avatar(comment.user, true)}<strong>@${escape(comment.user)}</strong><span>${comment.side === 'LEFT' ? 'Original' : 'New'} line ${comment.line}</span>${draft ? '<span class="draft-label">Draft</span>' : ''}${outdated ? '<span class="outdated">Outdated</span>' : ''}</div><p>${escape(comment.body)}</p>${draft ? `<button class="text-button" data-remove-draft="${escape(comment.id)}">Discard draft</button>` : `<button class="text-button" data-reply="${escape(comment.id)}">Reply</button>`}</article>`;
}

function reviewPane() {
  const file = selected();
  const isMine = owns(file) && page.current;
  const status = fileStatus(file, state);
  const comments = state.comments.filter(comment => comment.file === file.id);
  const drafts = myDrafts().filter(comment => comment.file === file.id);
  const decision = myDecision(file);
  const staged = stagedDecision(file);
  return `<section class="review-pane"><div class="editor-toolbar"><div class="editor-file"><span class="codicon codicon-file-code" aria-hidden="true"></span><strong>${escape(file.name)}</strong><span class="changes"><span>+${file.additions}</span><span>−${file.deletions}</span></span></div><div class="editor-actions"><button class="button small ghost" data-action="layout"><span class="codicon codicon-split-horizontal" aria-hidden="true"></span>${state.split ? 'Unified' : 'Split'}</button><button class="button small ghost" data-action="comment" ${!isMine ? 'disabled' : ''}><span class="codicon codicon-comment" aria-hidden="true"></span>Add comment</button></div></div>
    <div class="file-breadcrumb" title="${escape(file.directory + '/' + file.name)}">${escape(file.directory)}<span>/</span><strong>${escape(file.name)}</strong></div><div id="editor" aria-label="Diff for ${escape(file.name)}"></div>${file.contentError?`<p class="decision-reason">${escape(file.contentError)} · <a href="https://github.com/${escape(page.review.identity.repository)}/pull/${page.review.identity.pr}/files">Open files on GitHub</a></p>`:''}
    <div class="file-decision-bar"><div class="decision-summary"><span class="decision-label">Your decision</span><span class="${decision?.kind === 'approve' ? 'approved' : decision?.kind === 'changes' ? 'blocked' : ''}">${isMine ? decision ? `${decision.kind === 'approve' ? 'Approved' : 'Rejected'}${staged ? ' · unpublished' : ' · submitted'}` : 'Not reviewed' : 'Read-only · not your file'}</span></div>${isMine ? `<div class="decision-actions"><button class="button small approve-file ${decision?.kind === 'approve' ? 'chosen' : ''}" data-action="approve-file" aria-pressed="${decision?.kind === 'approve'}"><span class="codicon codicon-check" aria-hidden="true"></span>Approve file</button><button class="button small reject-file ${decision?.kind === 'changes' ? 'chosen' : ''}" data-action="reject-file" aria-pressed="${decision?.kind === 'changes'}"><span class="codicon codicon-close" aria-hidden="true"></span>Reject file</button>${staged ? '<button class="text-button undo-decision" data-action="undo-decision">Undo</button>' : ''}</div>` : ''}</div>
    ${decision?.kind === 'changes' ? `<div class="decision-reason">${escape(decision.body)}</div>` : ''}
    <div class="file-review-state"><span class="status-tag ${status.state}"><span class="file-dot ${status.state}"></span>${statusLabel[status.state]}</span><span>Required owner approvals</span></div>
    <section class="conversation ${comments.length + drafts.length ? 'has-comments' : ''}"><div class="conversation-heading"><h2><span class="codicon codicon-comment-discussion" aria-hidden="true"></span>Comments <span>${comments.length + drafts.length}</span></h2><span>${drafts.length ? `${drafts.length} unpublished ${drafts.length === 1 ? 'draft' : 'drafts'}` : 'Publish with your review'}</span></div>${[...comments.map(c => commentCard(c)), ...drafts.map(c => commentCard(c, true))].join('')}</section></section>`;
}

function progressPanel() {
  const data = summary();
  const file = selected();
  const status = fileStatus(file, state);
  const remaining = undecidedFiles().length;
  const decisionCount = mine().length - remaining;
  const publishable = myPendingDecisions().length || myDrafts().length;
  return `<aside class="progress-panel"><div class="review-context"><section class="progress-overview"><div class="section-label">Pull request status</div><div class="gate-state ${data.ready ? 'approved' : data.blocked ? 'blocked' : ''}"><span class="codicon codicon-${data.ready ? 'pass' : data.blocked ? 'error' : 'circle-large-outline'}" aria-hidden="true"></span>${data.ready ? 'Reviews complete' : data.blocked ? 'Changes requested' : 'Review required'}</div><div class="approval-summary"><span>Files approved</span><strong>${data.approved} / ${data.owned.length}</strong></div><div class="progress-track"><span style="width:${(data.owned.length ? data.approved / data.owned.length * 100 : 0)}%"></span></div></section>
    <section class="file-ownership"><div class="section-label">Owners of ${escape(file.name)}</div><p class="ownership-mode">${file.requirements.length > 1 ? 'Every matching rule must be satisfied (see rules below)' : file.all ? 'All listed owners must approve' : file.owners.length ? 'One owner must approve' : 'No owner assigned'}</p>${file.owners.map(user => `<div class="reviewer-row">${avatar(user, true)}<strong>@${escape(user)}</strong><span class="owner-decision ${status.activeBlocks.some(b => b.user === user) ? 'blocked' : status.approvals.has(user) ? 'approved' : ''}" title="${status.activeBlocks.some(b => b.user === user) ? 'Changes requested' : status.approvals.has(user) ? 'Approved' : 'Awaiting approval'}"><span class="codicon codicon-${status.activeBlocks.some(b => b.user === user) ? 'error' : status.approvals.has(user) ? 'check' : 'circle-outline'}" aria-hidden="true"></span></span></div>`).join('')}
    <details class="ownership-details"><summary>Why these owners?</summary><div><code>${escape(file.rule || 'No matching rule')}</code><button class="text-button" data-tab="ownership">CODETURTLE.md (or legacy OWNERS)${file.rule ? `:${file.ruleLine}` : ''} ↗</button><p>${file.rule ? 'Matching ownership rule on the target branch.' : 'This file has no matching ownership rule.'}</p></div></details></section>
    ${status.activeBlocks.map(block => `<div class="block-card"><strong>@${escape(block.user)} requested changes</strong><p>${escape(block.body || 'This file needs another look.')}</p>${page.admin ? `<button class="button small warning" data-override="${escape(block.user)}">Override block</button>` : '<span>The reviewer or a repository admin can clear this block.</span>'}</div>`).join('')}
    <section class="all-reviewers"><div class="section-label">All reviewers <span>Files approved</span></div>${Object.keys(reviewers).map(user => `<div class="reviewer-row">${avatar(user, true)}<strong>@${escape(user)}</strong><span class="review-count">${reviewerProgress(user)}</span></div>`).join('')}</section>
    <details class="activity"><summary>Activity <span>${state.activity.length}</span></summary>${state.activity.slice(-4).reverse().map(event => `<div><p>${escape(event.text)}</p><span>${escape(event.at)}</span></div>`).join('')}</details>
    </div><div class="submit-section">${myDrafts().filter(d=>d.revision!==state.revision[d.file]).map(d=>`<p class="outdated">Outdated draft: ${escape(d.file)} <button class="text-button" data-remove-draft="${escape(d.id)}">Discard outdated draft</button></p>`).join('')}<div class="your-review-progress"><span>Your review</span><strong>${decisionCount} / ${mine().length} files</strong></div><p>${remaining ? `Decide on ${remaining === 1 ? 'the remaining file' : `each of the ${remaining} remaining files`}` : 'Every file has an explicit decision'}</p><button class="button primary" data-action="submit" ${!page.current || remaining || !publishable ? 'disabled' : ''}>Submit review<span class="codicon codicon-arrow-right" aria-hidden="true"></span></button><span>${publishable ? `${myPendingDecisions().length} ${myPendingDecisions().length === 1 ? 'decision' : 'decisions'} · ${myDrafts().length} ${myDrafts().length === 1 ? 'comment' : 'comments'} unpublished` : remaining ? 'Approve or reject each file in the diff' : 'No unpublished decisions or comments'}</span></div></aside>`;
}

function githubPreview() {
 const data=summary();
 return `<main class="preview-page"><div class="preview-heading"><span class="eyebrow">GITHUB · PR CONVERSATION</span><h2>GitHub comment</h2><p>CodeTurtle updates its PR comment after submitted reviews.</p></div><div class="github-shell"><div class="github-comment"><div class="github-comment-header"><img class="brand-logo" src="/codeturtle.svg" alt=""/><strong>codeturtle[bot]</strong></div><div class="github-comment-body"><h3>CodeTurtle · Owner review</h3><p>${data.approved} of ${data.owned.length} owned files approved</p><table><thead><tr><th>Reviewer</th><th>Parts</th><th>Review</th></tr></thead><tbody>${Object.keys(reviewers).map(user=>`<tr><td>@${escape(user)}</td><td>${files.filter(f=>f.owners.includes(user)).map(f=>escape(f.id)).join('<br>')}</td><td><a href="/?run=${encodeURIComponent(page.review.run_id)}&reviewer=${encodeURIComponent('@'+user)}">Open individual review</a></td></tr>`).join('')}</tbody></table>${state.overrides.map(o=>`<p>Admin @${escape(o.by)} overrode @${escape(o.user)}’s block: ${escape(o.reason)}</p>`).join('')}<p>Publication: ${escape(page.review.deliveries.github?.status || 'pending')}. This review state does not enforce a GitHub branch protection check.</p></div></div></div></main>`;
}
function slackPreview() {
 return `<main class="preview-page"><div class="preview-heading"><h2>Slack</h2><p>Slack is not connected for this setup. Reviews and assignments are available in the GitHub PR comment.</p></div></main>`;
}
function ownershipPreview() {
 return `<main class="ownership-page"><div class="preview-heading"><span class="eyebrow">OWNERSHIP · TARGET BRANCH</span><h2>Ownership rules</h2><p>CODETURTLE.md supplies the rules, with legacy OWNERS supported. Matching rules accumulate.</p></div><pre>${escape(ownership)}</pre><div class="rule-explanations"><article><h3>Review what you own</h3><p>Any listed owner can sign off by default. Rules marked All require every listed owner.</p></article><article><h3>Every file gets a decision</h3><p>Decisions and comments remain private until Submit review. Changed files need fresh decisions; unchanged files retain their approvals.</p></article><article><h3>Accountable overrides</h3><p>Repository administrators can clear a block with an audited reason. An override does not supply an approval.</p></article></div></main>`;
}

function render() {
  diffEditor?.dispose(); models.forEach(model => model.dispose()); models = [];
  app.innerHTML = header() + (state.tab === 'review' ? `<main class="workspace">${fileTree()}${reviewPane()}${progressPanel()}</main>` : state.tab === 'github' ? githubPreview() : state.tab === 'slack' ? slackPreview() : ownershipPreview()) + '<div id="toast" role="status" aria-live="polite"></div>';
  if (state.tab !== 'review') return;
  const file = selected();
  const modified = file.modified;
  models = [monaco.editor.createModel(file.original, file.language), monaco.editor.createModel(modified, file.language)];
  diffEditor = monaco.editor.createDiffEditor(document.querySelector<HTMLElement>('#editor')!, { theme: 'codeturtle', readOnly: true, originalEditable: false, renderSideBySide: state.split, useInlineViewWhenSpaceIsLimited: true, automaticLayout: true, minimap: { enabled: false }, fontSize: 13, lineHeight: 22, fontFamily: 'Hack, monospace', scrollBeyondLastLine: false, glyphMargin: true, lineNumbersMinChars: 3, renderOverviewRuler: false, diffCodeLens: false, wordWrap: 'on', stickyScroll: { enabled: false }, accessibilitySupport: 'on', padding: { top: 16, bottom: 16 }, hideUnchangedRegions: { enabled: false } });
  diffEditor.setModel({ original: models[0], modified: models[1] });
  for (const [editor, side] of [[diffEditor.getOriginalEditor(), 'LEFT'], [diffEditor.getModifiedEditor(), 'RIGHT']] as const) {
    editor.addAction({ id: `codeturtle-comment-${side}`, label: 'Draft a CodeTurtle comment', contextMenuGroupId: 'navigation', contextMenuOrder: 1, run: () => openComment(editor.getPosition()?.lineNumber || 1, side) });
    editor.onMouseDown(event => {
      if (event.target.type === monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN && event.target.position) openComment(event.target.position.lineNumber, side);
    });
    const comments = [...state.comments, ...myDrafts()].filter(c => c.file === file.id && c.side === side && c.revision === state.revision[file.id]);
    editor.createDecorationsCollection(comments.map(c => ({ range: new monaco.Range(c.line, 1, c.line, 1), options: { isWholeLine: true, className: 'codeturtle-comment-line', glyphMarginClassName: 'codeturtle-comment-glyph', glyphMarginHoverMessage: { value: `CodeTurtle comment by @${c.user}` } } })));
  }
}

function toast(message: string) {
  const node = document.querySelector<HTMLElement>('#toast')!; node.textContent = message; node.classList.add('visible');
  setTimeout(() => node.classList.remove('visible'), 4500);
}

function modal(content: string, onSubmit: (data: FormData, dialog: HTMLDialogElement) => void | Promise<void>) {
  const dialog = document.createElement('dialog');
  dialog.className = 'codeturtle-dialog'; dialog.innerHTML = `<form>${content}</form>`;
  document.body.append(dialog);
  dialog.addEventListener('close', () => dialog.remove());
  dialog.querySelector('[data-cancel]')?.addEventListener('click', () => dialog.close());
  dialog.querySelector('form')!.addEventListener('submit', async event => {
    event.preventDefault(); if (busy) return;
    const form = event.target as HTMLFormElement;
    const submit = form.querySelector<HTMLButtonElement>('[type="submit"]')!;
    const label = submit.textContent;
    const data = new FormData(form);
    submit.disabled = true; submit.textContent = 'Saving…';
    dialog.querySelector('.form-error')?.remove();
    try { await onSubmit(data, dialog); }
    catch (e) {
      const error = document.createElement('p'); error.className = 'form-error';
      error.textContent = e instanceof Error && e.message === 'service_unavailable'
        ? 'The service is temporarily unavailable. Your text is still here; try saving again.'
        : String(e instanceof Error ? e.message : e);
      dialog.append(error);
    } finally { submit.disabled = false; submit.textContent = label; }
  });
  dialog.showModal(); return dialog;
}

function openComment(line: number, side: Side = 'RIGHT', replyTo: string | null = null) {
  const file = selected();
  if (!owns(file) || !page.current) { toast('You can comment on files you own.'); return; }
  const draftId = crypto.randomUUID();
  modal(`<div class="modal-eyebrow">DRAFT COMMENT</div><h2>${replyTo ? 'Reply to this thread' : 'Leave a note'}</h2><p>${escape(file.name)} · ${side === 'LEFT' ? 'original' : 'new'} line ${line}</p><label class="field-label" for="comment-body">Comment</label><textarea id="comment-body" name="body" required rows="5" placeholder="What should the author know?" autofocus></textarea><div class="modal-note">This stays private until you submit your review.</div><div class="modal-actions"><button class="button ghost" type="button" data-cancel>Cancel</button><button class="button primary" type="submit">Save draft</button></div>`, async (data, dialog) => {
    const body = String(data.get('body') || '').trim(); if (!body) return;
    state.drafts = state.drafts.filter(draft => draft.id !== draftId);
    state.drafts.push({ id: draftId, file: file.id, revision: state.revision[file.id], user: state.user, line, side, body, replyTo });
    await saveDrafts(); dialog.close(); render(); toast('Draft saved. It will publish with your review.');
  });
}

async function stageDecision(kind: Decision['kind'], body = '') {
  const file = selected();
  if (!owns(file) || !page.current) return;
  state.pendingDecisions = state.pendingDecisions.filter(decision => !(decision.file === file.id && decision.user === state.user));
  state.pendingDecisions.push({ id: crypto.randomUUID(), file: file.id, user: state.user, revision: state.revision[file.id], kind, body });
  await saveDrafts(); render();
}

function rejectFile() {
  const file = selected();
  if (!owns(file) || !page.current) return;
  modal(`<div class="modal-eyebrow">FILE DECISION</div><h2>Reject ${escape(file.name)}</h2><p>Request changes on this file. Other files keep their own decisions.</p><label class="field-label" for="rejection-reason">What needs to change?</label><textarea id="rejection-reason" name="reason" rows="4" required autofocus placeholder="Explain the issue in this file">${escape(myDecision(file)?.kind === 'changes' ? myDecision(file)?.body : '')}</textarea><div class="modal-note">This decision stays private until you submit your review.</div><div class="form-error" role="alert"></div><div class="modal-actions"><button class="button ghost" type="button" data-cancel>Cancel</button><button class="button reject-file" type="submit">Save rejection</button></div>`, async (data, dialog) => {
    const reason = String(data.get('reason') || '').trim();
    if (!reason) { dialog.querySelector('.form-error')!.textContent = 'Explain what needs to change in this file.'; return; }
    await stageDecision('changes', reason); dialog.close();
  });
}

function openReview() {
  if (undecidedFiles().length) { toast('Approve or reject each of your files before submitting.'); return; }
  const pending = myPendingDecisions();
  const drafts = myDrafts();
  if (!pending.length && !drafts.length) return;
  modal(`<div class="modal-eyebrow">PUBLISH REVIEW</div><h2>Submit your review</h2><p>Publish the decisions you made individually. No other files will be approved.</p><div class="review-decisions">${pending.map(decision => `<div><span>${escape(files.find(file => file.id === decision.file)?.name || decision.file)}</span><strong class="${decision.kind === 'approve' ? 'approved' : 'blocked'}">${decision.kind === 'approve' ? 'Approve' : 'Reject'}</strong>${decision.kind === 'changes' ? `<p>${escape(decision.body)}</p>` : ''}</div>`).join('')}</div><div class="modal-note">${drafts.length} draft ${drafts.length === 1 ? 'comment' : 'comments'} will publish with this review. Return to a file to change its decision.</div><div class="form-error" role="alert"></div><div class="modal-actions"><button class="button ghost" type="button" data-cancel>Back to files</button><button class="button primary" type="submit">Publish review</button></div>`, async (data, dialog) => {
    const fail = (message: string) => { dialog.querySelector('.form-error')!.textContent = message; };
    if (undecidedFiles().length) { fail('A file still needs an explicit decision. Return to your files.'); return; }
    if (pending.some(decision => decision.revision !== state.revision[decision.file]) || drafts.some(draft => draft.revision !== state.revision[draft.file])) { fail('A decision or comment refers to an older revision. Review that file again and discard any outdated comments.'); return; }
    await publish(); dialog.close(); render(); toast('Review published. The GitHub comment update is queued.');
  });
}

function openOverride(user: string) {
  if (!page.admin) return;
  const file = selected();
  const block = fileStatus(file, state).activeBlocks.find(decision => decision.user === user);
  if (!block) return;
  modal(`<div class="modal-eyebrow">REPOSITORY ADMIN OVERRIDE</div><h2>Override this block?</h2><p>Clear @${escape(user)}'s changes request on <strong>${escape(file.name)}</strong>.</p><label class="field-label" for="override-reason">Reason for override</label><textarea id="override-reason" name="reason" required minlength="10" rows="4" placeholder="Explain why this can proceed"></textarea><div class="modal-note">Your name and reason will appear in CodeTurtle and the PR comment. Required file sign-offs still apply.</div><div class="modal-actions"><button class="button ghost" type="button" data-cancel>Cancel</button><button class="button warning" type="submit">Confirm override</button></div>`, async (data, dialog) => {
    const reason = String(data.get('reason') || '').trim(); if (reason.length < 10) return;
    await overrideBlock(block.id, reason); dialog.close(); render(); toast('Override recorded. Required approvals still apply.');
  });
}

app.addEventListener('click', event => { void handleClick(event).catch(e=>toast(e instanceof Error?e.message:String(e))); });
async function handleClick(event: MouseEvent) {
  const button = (event.target as Element).closest('button'); if (!button || button.disabled || busy) return;
  if (button.dataset.tab) { state.tab = button.dataset.tab; render(); return; }
  if (button.dataset.file) { state.selected = button.dataset.file; await loadContent(selected()); render(); return; }
  if (button.dataset.override) { openOverride(button.dataset.override); return; }
  if (button.dataset.removeDraft) { state.drafts = state.drafts.filter(d => d.id !== button.dataset.removeDraft); await saveDrafts(); render(); return; }
  if (button.dataset.reply) { const comment = state.comments.find(c => c.id === button.dataset.reply)!; openComment(comment.line, comment.side, comment.id); return; }
  switch (button.dataset.action) {
    case 'show-all': state.showAll = !state.showAll; if (!state.showAll && !owns(selected())) state.selected = mine()[0]?.id || files[0]?.id || ''; await loadContent(selected()); render(); break;
    case 'layout': state.split = !state.split; render(); break;
    case 'comment': openComment(diffEditor?.getModifiedEditor().getPosition()?.lineNumber || 1); break;
    case 'approve-file': await stageDecision('approve'); break;
    case 'reject-file': rejectFile(); break;
    case 'undo-decision': state.pendingDecisions = state.pendingDecisions.filter(decision => !(decision.file === state.selected && decision.user === state.user)); await saveDrafts(); render(); break;
    case 'submit': openReview(); break;
  }
}

async function start() {
 if (!new URLSearchParams(location.search).has('run')) { await dashboard(); return; }
 await load();
 if(!files.length) { app.innerHTML=header()+'<main class="preview-page">No changed files are available in this report.</main>'; return; }
 await loadContent(selected()); render();
}
void start().catch(e=>{ if(e instanceof SignInRequired)return;app.replaceChildren();const p=document.createElement('p');p.textContent=e instanceof Error?e.message:String(e);app.append(p);const a=document.createElement('a');a.href='/';a.textContent='Back to repositories';app.append(a); });
