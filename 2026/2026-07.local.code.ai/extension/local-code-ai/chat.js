// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Local Code AI - chat.
// A webview chat that talks to the local Ollama server (/api/chat, streaming) and
// is aware of the open VS Code project: every request carries a live workspace
// snapshot, and the model can call read-only tools (list_files/read_file/
// search_text/...) to inspect the code itself. Conversation history lives in the
// ChatSession until "New chat".
//
// The same ChatSession drives two surfaces:
//   ChatViewProvider - the activity-bar side bar view.
//   ChatPanel        - a webview panel, i.e. a normal editor tab in any group.
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const ws = require('./workspace');

const PANEL_TYPE = 'localCodeAI.chatPanel';

// ---------------------------------------------------------------------------
// Status lines, one per line in cli\*.txt. The "Thinking" indicator (chat
// webview and the refactor progress notification) cycles through the words in
// cli/progress.txt; every finished chat turn signs off with the next line from
// cli/done.txt, round-robin. Both fall back to built-in lists if the file is
// missing or empty.
// ---------------------------------------------------------------------------
const FALLBACK_PROGRESS_WORDS = [
  'Thinking', 'Pondering', 'Reasoning', 'Reflecting', 'Contemplating',
  'Analyzing', 'Processing', 'Considering', 'Deliberating', 'Evaluating'
];
const FALLBACK_DONE_LINES = [
  'Done! Ready for more.', 'All set - send the next one.',
  'Finished! What else can I look at?', 'That one is done - keep them coming.',
  'Wrapped up. Ready when you are.', 'Done here. What is next?',
  'Complete! Awaiting your next prompt.', 'Task finished - your move.',
  'Done! Point me at the next thing.', 'All done. Fire away.'
];

function loadLineFile(name, fallback) {
  try {
    const lines = fs.readFileSync(path.join(__dirname, 'cli', name), 'utf8')
      .split(/\r?\n/).map(s => s.trim()).filter(Boolean);
    if (lines.length) return lines;
  } catch { /* fall through to the built-in list */ }
  return fallback;
}

function loadProgressWords() { return loadLineFile('progress.txt', FALLBACK_PROGRESS_WORDS); }
function loadDoneLines() { return loadLineFile('done.txt', FALLBACK_DONE_LINES); }

// ---------------------------------------------------------------------------
// Session: history + Ollama round trips + the tool loop. Surface-agnostic.
// ---------------------------------------------------------------------------
class ChatSession {
  /**
   * @param {() => object} getConfig
   * @param {(msg: string) => void} log
   */
  constructor(getConfig, log) {
    this.getConfig = getConfig;
    this.log = log;
    this.history = [];        // Ollama messages: user / assistant / tool
    this.abort = null;        // AbortController of the in-flight request
    this.attachments = [];    // Uri[] the user picked for the next message
    this.toolsUnsupported = false;
    this.webview = null;
  }

  // Bind the session to a webview and wire its messages back to us.
  attach(webview) {
    this.webview = webview;
    webview.onDidReceiveMessage(m => {
      if (m.type === 'send') this.send(m.text, m.opts).catch(e => this.fail(e.message || String(e)));
      else if (m.type === 'stop') { if (this.abort) this.abort.abort(); }
      else if (m.type === 'reset') { this.reset(); }
      else if (m.type === 'attach') this.pickAttachments().catch(e => this.fail(e.message || String(e)));
      else if (m.type === 'openEditor') vscode.commands.executeCommand('localCodeAI.openChatInEditor');
    });
  }

  post(msg) { if (this.webview) this.webview.postMessage(msg); }

  fail(text) {
    this.log(`[chat] ${text}`);
    this.post({ type: 'error', text });
  }

  reset() {
    this.history = [];
    this.attachments = [];
    if (this.abort) this.abort.abort();
    this.post({ type: 'attachments', items: [] });
  }

  async pickAttachments() {
    const cfg = this.getConfig();
    const exclude = (cfg.excludeGlobs || []).length ? `{${cfg.excludeGlobs.join(',')}}` : undefined;
    const uris = await vscode.workspace.findFiles('**/*', exclude, 5000);
    if (!uris.length) { this.post({ type: 'note', text: '(no files found in the workspace)' }); return; }
    const picks = await vscode.window.showQuickPick(
      uris.map(u => ({ label: path.basename(u.fsPath), description: vscode.workspace.asRelativePath(u), uri: u })),
      { canPickMany: true, placeHolder: 'Attach files to the next message' });
    if (!picks) return;
    for (const p of picks) {
      if (!this.attachments.some(u => u.toString() === p.uri.toString())) this.attachments.push(p.uri);
    }
    this.post({ type: 'attachments', items: this.attachments.map(u => vscode.workspace.asRelativePath(u)) });
  }

  async send(userText, opts) {
    if (this.abort) { this.fail('A reply is already in progress - press Stop first.'); return; }
    const cfg = this.getConfig();
    opts = opts || {};

    // Attachments the user explicitly ticked/picked go into the user message.
    const att = await ws.buildAttachments(cfg, opts, this.attachments);
    const content = att.text ? `${att.text}\n\n${userText}` : userText;
    if (att.notes.length) this.post({ type: 'note', text: `(attached: ${att.notes.join(', ')})` });
    this.attachments = [];
    this.post({ type: 'attachments', items: [] });

    this.history.push({ role: 'user', content });
    const historyMark = this.history.length - 1;   // rewind point if the request dies

    // The workspace snapshot is rebuilt per request and never stored in history,
    // so it can never go stale as the user edits the project.
    let system = cfg.chatSystemPrompt;
    if (opts.includeProject !== false) {
      const context = await ws.buildContextBlock(cfg, opts);
      system = `${system}\n\n${context}`;
    }

    const useTools = cfg.chatTools && !this.toolsUnsupported && opts.includeProject !== false;
    this.abort = new AbortController();
    this.post({ type: 'start' });
    let lastReply = '';
    try {
      for (let round = 0; round <= cfg.chatMaxToolRounds; round++) {
        const messages = [{ role: 'system', content: system }, ...this.history];
        const turn = await this.stream(messages, useTools && round < cfg.chatMaxToolRounds, cfg);
        lastReply = turn.content;

        // Small models routinely write the tool call as JSON text (fenced,
        // <tool_call>-wrapped, or bare) instead of using the native mechanism;
        // Ollama cannot parse those into tool_calls, so the raw JSON would end
        // the turn as the visible "answer". Lift such calls out of the text and
        // feed them to the normal tool loop.
        if (!turn.toolCalls.length && useTools && round < cfg.chatMaxToolRounds) {
          const rescued = extractTextToolCalls(turn.content);
          if (rescued.calls.length) {
            this.log(`[chat] rescued ${rescued.calls.length} tool call(s) written as text`);
            turn.toolCalls = rescued.calls;
            turn.content = rescued.content;
            this.post({ type: 'replace', text: turn.content });
          }
        }

        if (!turn.toolCalls.length) {
          if (turn.content) this.history.push({ role: 'assistant', content: turn.content });
          break;
        }
        // The model wants to look at the project: run each call, feed results back.
        this.history.push({ role: 'assistant', content: turn.content, tool_calls: turn.toolCalls });
        for (const call of turn.toolCalls) {
          const name = call.function && call.function.name;
          const args = parseArgs(call.function && call.function.arguments);
          this.post({ type: 'tool', text: ws.describeCall(name, args) });
          this.log(`[chat] tool ${name} ${JSON.stringify(args)}`);
          const result = await ws.runTool(name, args, cfg);
          this.history.push({ role: 'tool', tool_name: name, content: result });
        }
        if (round === cfg.chatMaxToolRounds - 1) {
          this.history.push({ role: 'user', content: 'Tool budget exhausted. Answer now with what you have.' });
        }
      }
    } catch (e) {
      if (e.name === 'AbortError') {
        this.post({ type: 'note', text: '(stopped)' });
        if (lastReply) this.history.push({ role: 'assistant', content: lastReply });
      } else {
        this.history.length = historyMark;   // let the user resend after fixing it
        const msg = String(e.message || e);
        this.fail(`Ollama not reachable or failed at ${cfg.endpoint}: ${msg}. Is 'ollama serve' running?`);
        // Connection-level failures (refused, or the server died mid-stream)
        // mean the server is down - offer the one-click fix. Anything else is
        // the server rejecting the request (broken model, OOM) - point at the
        // diagnosis command instead.
        if (/fetch failed|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|socket hang up|terminated|other side closed|ECONNRESET/i.test(msg)) {
          vscode.window.showErrorMessage(`Local Code AI: cannot reach Ollama at ${cfg.endpoint}.`, 'Start Model')
            .then(pick => { if (pick === 'Start Model') vscode.commands.executeCommand('localCodeAI.startModel'); });
        } else {
          vscode.window.showErrorMessage(`Local Code AI: the model request failed (${msg.slice(0, 140)}).`, 'Check Setup')
            .then(pick => { if (pick === 'Check Setup') vscode.commands.executeCommand('localCodeAI.checkSetup'); });
        }
      }
    } finally {
      this.abort = null;
      this.post({ type: 'done' });
    }
  }

  // One streamed /api/chat round trip. Returns the assistant text plus any tool
  // calls the model emitted.
  async stream(messages, withTools, cfg) {
    const body = {
      model: cfg.model,
      stream: true,
      options: { temperature: cfg.temperature },
      messages
    };
    if (withTools) body.tools = ws.TOOL_SPECS;

    const resp = await fetch(`${cfg.endpoint}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: this.abort.signal
    });
    if (!resp.ok) {
      const errTxt = (await resp.text().catch(() => '')).slice(0, 300);
      // Older/smaller models reject tools; drop them once and retry plainly.
      if (withTools && /tool/i.test(errTxt)) {
        this.toolsUnsupported = true;
        this.post({ type: 'note', text: `(model '${cfg.model}' does not support tools - continuing with the workspace summary only)` });
        this.log(`[chat] tools disabled: ${errTxt}`);
        return this.stream(messages, false, cfg);
      }
      throw new Error(`HTTP ${resp.status} from Ollama: ${errTxt}`);
    }

    // Ollama streams NDJSON: one {"message":{...},"done":false} per line.
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '', content = '';
    const toolCalls = [];
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        let data;
        try { data = JSON.parse(line); } catch { continue; }
        if (data.error) throw new Error(data.error);
        const msg = data.message;
        if (!msg) continue;
        if (msg.content) { content += msg.content; this.post({ type: 'delta', text: msg.content }); }
        if (Array.isArray(msg.tool_calls)) toolCalls.push(...msg.tool_calls);
      }
    }
    return { content, toolCalls };
  }
}

// Ollama sends arguments as an object; some models send a JSON string.
function parseArgs(raw) {
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  try { return JSON.parse(raw); } catch { return {}; }
}

// Names the model may call; JSON in the reply naming anything else stays prose.
const TOOL_NAMES = new Set(ws.TOOL_SPECS.map(t => t.function.name));

// Index just past the JSON object starting at text[start] ('{'), honoring
// strings and escapes; -1 if the braces never balance.
function scanJsonObject(text, start) {
  let depth = 0, inString = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === '\\') i++;
      else if (c === '"') inString = false;
    }
    else if (c === '"') inString = true;
    else if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return i + 1; }
  }
  return -1;
}

// Recover tool calls a model wrote as reply text instead of emitting through
// the native mechanism. Any {"name": ..., "arguments"|"parameters": ...} object
// naming a real tool counts, wherever it sits (``` fence, <tool_call> tag, or
// bare). Returns the calls in native tool_calls shape plus the reply text with
// the JSON (and the wrappers it left empty) removed.
function extractTextToolCalls(text) {
  const calls = [];
  let kept = '', i = 0;
  while (i < text.length) {
    if (text[i] !== '{') { kept += text[i++]; continue; }
    const end = scanJsonObject(text, i);
    let obj = null;
    if (end !== -1) {
      try { obj = JSON.parse(text.slice(i, end)); } catch { /* not JSON - keep as prose */ }
    }
    if (obj && typeof obj.name === 'string' && TOOL_NAMES.has(obj.name)) {
      calls.push({ function: { name: obj.name, arguments: obj.arguments || obj.parameters || {} } });
      i = end;
    } else {
      kept += text[i++];
    }
  }
  if (!calls.length) return { calls, content: text };
  const content = kept
    .replace(/```(?:json)?\s*```/g, '')
    .replace(/<tool_call>\s*<\/tool_call>/g, '')
    .trim();
  return { calls, content };
}

// ---------------------------------------------------------------------------
// Surface 1: side bar view. The chat's home is an editor tab, so by default
// this view is only a LAUNCHER page (no chat session behind it): when it first
// materializes (the activity-bar click), it closes the side bar and opens the
// editor-tab chat; if it becomes visible again later, it opens the tab but
// leaves the side bar alone - the view may have been dragged to the panel or
// the secondary side bar, where 'closeSidebar' would slam an unrelated view.
// It becomes a real chat only on request: the "Open Chat in Side Bar" command
// (one-shot allow flag) or the chatOpenIn=sidebar setting.
// ---------------------------------------------------------------------------
class ChatViewProvider {
  constructor(getConfig, log) {
    this.session = new ChatSession(getConfig, log);
    this.getConfig = getConfig;
    this.allowSidebar = false;
    this.view = null;
    this.showingChat = false;
    this.resolvedBefore = false;
  }

  allowSidebarOnce() {
    this.allowSidebar = true;
    // Consumed when the view resolves; if it is already resolved, swap it to a
    // chat right now. Either way the flag must not linger into the next
    // activity-bar click.
    this.showChat();
    setTimeout(() => { this.allowSidebar = false; }, 2000);
  }

  showChat() {
    if (!this.view || this.showingChat) return;
    this.showingChat = true;
    this.view.webview.html = chatHtml('sidebar');
  }

  resolveWebviewView(view) {
    this.view = view;
    view.webview.options = { enableScripts: true };
    this.session.attach(view.webview);
    view.onDidDispose(() => {
      if (this.view === view) { this.view = null; this.showingChat = false; }
    });
    // A re-resolve means a fresh webview DOM (view dragged to another
    // container, sidebar-mode restore): the transcript is gone, so the session
    // history must go too or the model would answer from invisible context.
    if (this.resolvedBefore && this.session.history.length) this.session.reset();
    this.resolvedBefore = true;

    if (this.getConfig().chatOpenIn === 'sidebar' || this.allowSidebar) {
      this.allowSidebar = false;
      this.showingChat = true;
      view.webview.html = chatHtml('sidebar');
      return;
    }
    this.showingChat = false;
    view.webview.html = launcherHtml();
    vscode.commands.executeCommand('workbench.action.closeSidebar');
    vscode.commands.executeCommand('localCodeAI.openChatInEditor');
    view.onDidChangeVisibility(() => {
      // Re-shown launcher: open the tab, do not touch the side bar (above).
      if (view.visible && !this.showingChat) vscode.commands.executeCommand('localCodeAI.openChatInEditor');
    });
  }
}

// The launcher page the activity-bar icon lands on when the chat lives in an
// editor tab. Kept trivial: one message, one button.
function launcherHtml() {
  return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
<style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); padding: 12px 10px; }
  p { opacity: 0.85; line-height: 1.5; }
  button {
    color: var(--vscode-button-foreground); background: var(--vscode-button-background);
    border: none; border-radius: 4px; padding: 6px 12px; cursor: pointer;
  }
  button:hover { background: var(--vscode-button-hoverBackground); }
</style>
</head>
<body>
  <p>The chat opens as an <b>editor tab</b>.</p>
  <button id="open">Open Chat</button>
  <p>Prefer it here? Run <i>"Local Code AI: Open Chat in Side Bar"</i> or set
  <i>localCodeAI.chatOpenIn</i> to <i>sidebar</i>.</p>
<script>
  const vscodeApi = acquireVsCodeApi();
  document.getElementById('open').addEventListener('click', () => vscodeApi.postMessage({ type: 'openEditor' }));
</script>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Surface 2: editor tab. This is a WebviewPanel, so VS Code lets the user put it
// in any editor group, split it, or drag it around - unlike a view, which is
// pinned to its activity-bar container.
// ---------------------------------------------------------------------------
class ChatPanel {
  static current = null;

  static createOrShow(getConfig, log, column) {
    const target = column || (vscode.window.activeTextEditor ? vscode.ViewColumn.Beside : vscode.ViewColumn.Active);
    if (ChatPanel.current) {
      ChatPanel.current.panel.reveal(target, false);
      return ChatPanel.current;
    }
    const panel = vscode.window.createWebviewPanel(PANEL_TYPE, 'Local Code AI Chat', target, {
      enableScripts: true,
      retainContextWhenHidden: true   // keep the transcript when the tab is hidden
    });
    return ChatPanel.adopt(panel, getConfig, log);
  }

  static adopt(panel, getConfig, log) {
    // Lazy deserialization can hand us a restored tab after 'Open Chat'
    // already created a live one; keep the live panel, drop the stale tab -
    // silently swapping the 'current' pointer would strand two chats.
    if (ChatPanel.current) {
      panel.dispose();
      return ChatPanel.current;
    }
    ChatPanel.current = new ChatPanel(panel, getConfig, log);
    return ChatPanel.current;
  }

  constructor(panel, getConfig, log) {
    this.panel = panel;
    this.session = new ChatSession(getConfig, log);
    panel.iconPath = undefined;
    panel.webview.options = { enableScripts: true };
    panel.webview.html = chatHtml('editor');
    this.session.attach(panel.webview);
    panel.onDidDispose(() => {
      if (this.session.abort) this.session.abort.abort();
      if (ChatPanel.current === this) ChatPanel.current = null;
    });
  }
}

// ---------------------------------------------------------------------------
// Webview HTML. Self-contained, themed with VS Code variables.
// Message text is inserted via textContent only (no HTML injection).
// ---------------------------------------------------------------------------
function chatHtml(surface) {
  const background = surface === 'editor' ? 'var(--vscode-editor-background)' : 'var(--vscode-sideBar-background)';
  return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
<style>
  html, body { height: 100%; }
  body {
    display: flex; flex-direction: column; margin: 0; padding: 4px;
    font-family: var(--vscode-font-family); font-size: var(--vscode-font-size);
    color: var(--vscode-foreground); background: ${background};
  }
  #messages { flex: 1; overflow-y: auto; padding: 4px 2px; }
  .msg { margin: 6px 0; padding: 6px 8px; border-radius: 6px; white-space: pre-wrap; word-break: break-word; }
  .user { background: var(--vscode-input-background); border: 1px solid var(--vscode-input-border, transparent); }
  .assistant { background: var(--vscode-editor-background); }
  .note { opacity: 0.65; font-style: italic; padding: 0 8px; }
  .thinking { font-style: italic; padding: 2px 8px; animation: pulse 2s ease-in-out infinite; }
  @keyframes pulse { 0%, 100% { opacity: 0.45; } 50% { opacity: 0.9; } }
  .tool { opacity: 0.8; padding: 1px 8px; font-family: var(--vscode-editor-font-family); font-size: 0.9em; }
  .tool::before { content: '\\1F50D  '; }
  .error { color: var(--vscode-errorForeground); padding: 2px 8px; white-space: pre-wrap; }
  #inputRow { display: flex; gap: 4px; align-items: flex-end; }
  textarea {
    flex: 1; resize: none; min-height: 3em; max-height: 10em;
    color: var(--vscode-input-foreground); background: var(--vscode-input-background);
    border: 1px solid var(--vscode-input-border, transparent); border-radius: 4px;
    font-family: inherit; font-size: inherit; padding: 4px 6px; box-sizing: border-box;
  }
  textarea:focus { outline: 1px solid var(--vscode-focusBorder); }
  button {
    color: var(--vscode-button-foreground); background: var(--vscode-button-background);
    border: none; border-radius: 4px; padding: 5px 10px; cursor: pointer;
  }
  button:hover { background: var(--vscode-button-hoverBackground); }
  button:disabled { opacity: 0.5; cursor: default; }
  #toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; padding: 2px 0 6px; }
  #toolbar label { display: flex; gap: 4px; align-items: center; opacity: 0.9; }
  #newChat, #attach { background: transparent; color: var(--vscode-foreground); border: 1px solid var(--vscode-input-border, #8884); }
  #chips { display: flex; gap: 4px; flex-wrap: wrap; padding: 0 0 4px; }
  .chip {
    background: var(--vscode-badge-background); color: var(--vscode-badge-foreground);
    border-radius: 10px; padding: 1px 8px; font-size: 0.85em;
  }
</style>
</head>
<body>
  <div id="toolbar">
    <label title="Send a live snapshot of the open project and let the model read files itself">
      <input type="checkbox" id="includeProject" checked> Project context
    </label>
    <label title="Send the full text of the active editor"><input type="checkbox" id="includeActiveFile"> Active file</label>
    <label title="Send the current editor selection"><input type="checkbox" id="includeSelection"> Selection</label>
    <span style="flex:1"></span>
    <button id="attach" title="Attach specific files to the next message">Attach...</button>
    <button id="newChat" title="Clear the conversation">New chat</button>
  </div>
  <div id="chips"></div>
  <div id="messages"></div>
  <div id="inputRow">
    <textarea id="input" placeholder="Ask about this project... (Enter to send, Shift+Enter for a new line)"></textarea>
    <button id="send">Send</button>
  </div>
<script>
  const vscodeApi = acquireVsCodeApi();
  const messagesEl = document.getElementById('messages');
  const chipsEl = document.getElementById('chips');
  const inputEl = document.getElementById('input');
  const sendBtn = document.getElementById('send');
  const projectEl = document.getElementById('includeProject');
  const activeEl = document.getElementById('includeActiveFile');
  const selectionEl = document.getElementById('includeSelection');
  let streamEl = null;   // the assistant bubble currently being streamed into
  let busy = false;
  let thinkingEl = null, thinkingTimer = null, thinkingWord = 0, thinkingDots = 0;

  // Waiting for the model can take minutes (CPU inference, tool rounds) with no
  // tokens arriving. Show a status line that grows a dot per second (up to 6),
  // then moves to the next word from progress.txt, so long waits look alive.
  const PROGRESS_WORDS = ${JSON.stringify(loadProgressWords()).replace(/</g, '\\u003c')};
  // Sign-off shown when a reply finishes, cycling through cli/done.txt.
  const DONE_LINES = ${JSON.stringify(loadDoneLines()).replace(/</g, '\\u003c')};
  let doneCount = 0;
  function renderThinking() {
    thinkingEl.textContent = PROGRESS_WORDS[thinkingWord % PROGRESS_WORDS.length] + '.'.repeat(thinkingDots);
  }
  function showThinking() {
    hideThinking();
    thinkingDots = 0;
    thinkingEl = document.createElement('div');
    thinkingEl.className = 'thinking';
    renderThinking();
    messagesEl.appendChild(thinkingEl);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    thinkingTimer = setInterval(() => {
      thinkingDots++;
      if (thinkingDots > 6) { thinkingDots = 0; thinkingWord++; }
      // Only follow the indicator if the user is already at the bottom -
      // never yank them out of scrollback during a long wait.
      const atBottom = messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight < 4;
      renderThinking();
      if (atBottom) messagesEl.scrollTop = messagesEl.scrollHeight;
    }, 1000);
  }
  function hideThinking() {
    if (thinkingTimer) { clearInterval(thinkingTimer); thinkingTimer = null; }
    if (thinkingEl) { thinkingEl.remove(); thinkingEl = null; }
  }

  function addBubble(cls, text) {
    const div = document.createElement('div');
    div.className = 'msg ' + cls;
    div.textContent = text;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    return div;
  }
  function addLine(cls, text) {
    const div = document.createElement('div');
    div.className = cls;
    div.textContent = text;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }
  function setBusy(b) {
    busy = b;
    sendBtn.textContent = b ? 'Stop' : 'Send';
  }

  function submit() {
    if (busy) { vscodeApi.postMessage({ type: 'stop' }); return; }
    const text = inputEl.value.trim();
    if (!text) return;
    addBubble('user', text);
    inputEl.value = '';
    vscodeApi.postMessage({
      type: 'send',
      text,
      opts: {
        includeProject: projectEl.checked,
        includeActiveFile: activeEl.checked,
        includeSelection: selectionEl.checked
      }
    });
  }

  sendBtn.addEventListener('click', submit);
  inputEl.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); }
  });
  document.getElementById('attach').addEventListener('click', () => vscodeApi.postMessage({ type: 'attach' }));
  document.getElementById('newChat').addEventListener('click', () => {
    vscodeApi.postMessage({ type: 'reset' });
    hideThinking();
    messagesEl.textContent = '';
    setBusy(false);
    inputEl.focus();
  });

  window.addEventListener('message', event => {
    const m = event.data;
    if (m.type === 'start') { setBusy(true); streamEl = addBubble('assistant', ''); showThinking(); }
    else if (m.type === 'delta') {
      hideThinking();
      if (!streamEl) streamEl = addBubble('assistant', '');
      streamEl.textContent += m.text;
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }
    else if (m.type === 'done') {
      hideThinking();
      if (streamEl && !streamEl.textContent) streamEl.remove();
      streamEl = null;
      addLine('note', DONE_LINES[doneCount++ % DONE_LINES.length]);
      setBusy(false);
      inputEl.focus();
    }
    else if (m.type === 'replace') {
      // A text-form tool call was lifted out of the reply; show what remains.
      if (!streamEl && m.text) streamEl = addBubble('assistant', '');
      if (streamEl) streamEl.textContent = m.text;
    }
    else if (m.type === 'tool') {
      // A tool ran mid-reply: close the current bubble so later text starts a new one.
      if (streamEl && !streamEl.textContent) streamEl.remove();
      streamEl = null;
      addLine('tool', m.text);
      showThinking();   // the model is off computing the next round
    }
    else if (m.type === 'note') { addLine('note', m.text); if (thinkingEl) messagesEl.appendChild(thinkingEl); }
    // Errors can be out-of-band (e.g. a failed Attach) while a reply is still
    // streaming; the reply's own 'done' resets busy and the indicator.
    else if (m.type === 'error') { addLine('error', m.text); }
    else if (m.type === 'attachments') {
      chipsEl.textContent = '';
      for (const item of m.items) {
        const span = document.createElement('span');
        span.className = 'chip';
        span.textContent = item;
        chipsEl.appendChild(span);
      }
    }
  });
</script>
</body>
</html>`;
}

module.exports = { ChatViewProvider, ChatPanel, ChatSession, PANEL_TYPE, loadProgressWords, loadDoneLines, extractTextToolCalls };
