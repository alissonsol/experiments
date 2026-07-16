// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Local Code AI - VS Code extension
// Chat sidebar backed by a local Ollama model, plus a refactor pipeline per file:
// deterministic formatter -> LLM refactor/comment cleanup -> formatter again.
// Edits are auto-applied and saved. No git operations are performed.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const os = require('os');
const { ChatViewProvider, ChatPanel, PANEL_TYPE, loadProgressWords } = require('./chat');

// ---------------------------------------------------------------------------
// Language registry
// ---------------------------------------------------------------------------
const LANGS = {
  go: {
    name: 'Go',
    exts: ['.go'],
    glob: '**/*.go',
    docStyle: 'godoc conventions (a `// Name ...` comment directly above each exported declaration)'
  },
  powershell: {
    name: 'PowerShell',
    exts: ['.ps1', '.psm1', '.psd1'],
    glob: '**/*.{ps1,psm1,psd1}',
    docStyle: 'comment-based help (<# .SYNOPSIS / .DESCRIPTION / .PARAMETER #>) for functions, `#` for inline comments'
  },
  rust: {
    name: 'Rust',
    exts: ['.rs'],
    glob: '**/*.rs',
    docStyle: 'rustdoc conventions (`///` doc comments on items, `//!` for module-level docs)'
  },
  javascript: {
    name: 'JavaScript',
    exts: ['.js', '.mjs', '.cjs', '.jsx'],
    glob: '**/*.{js,mjs,cjs,jsx}',
    docStyle: 'JSDoc conventions (`/** ... */` with @param/@returns where useful)'
  }
};

function languageForFile(fsPath) {
  const ext = path.extname(fsPath).toLowerCase();
  for (const key of Object.keys(LANGS)) {
    if (LANGS[key].exts.includes(ext)) return key;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Configuration / tool discovery
// ---------------------------------------------------------------------------
function getConfig() {
  const c = vscode.workspace.getConfiguration('localCodeAI');
  return {
    endpoint: (c.get('endpoint') || 'http://127.0.0.1:11434').replace(/\/+$/, ''),
    model: c.get('model') || 'localcoder',
    chatSystemPrompt: c.get('chatSystemPrompt') || 'You are a helpful coding assistant running fully locally. Be concise. Put code in markdown fences.',
    maxFilesBeforeWarning: c.get('maxFilesBeforeWarning') || 50,
    llmPass: c.get('llmPass') !== false,
    temperature: typeof c.get('temperature') === 'number' ? c.get('temperature') : 0.2,
    timeoutSeconds: c.get('timeoutSeconds') || 300,
    maxFileKB: c.get('maxFileKB') || 128,
    toolsRoot: c.get('toolsRoot') || '',
    excludeGlobs: c.get('excludeGlobs') || [],
    // Chat workspace awareness
    chatTools: c.get('chatTools') !== false,
    chatMaxToolRounds: c.get('chatMaxToolRounds') || 8,
    chatContextFileLimit: c.get('chatContextFileLimit') || 400,
    chatMaxReadKB: c.get('chatMaxReadKB') || 64,
    chatOpenIn: c.get('chatOpenIn') || 'editor'
  };
}

function defaultRoot() {
  if (process.platform === 'win32') return 'C:\\LocalCodeAI';
  return path.join(os.homedir(), 'LocalCodeAI');
}

// Reads tools/paths.json written by the setup script; every entry is optional.
function loadToolPaths(cfg, log) {
  const root = cfg.toolsRoot || process.env.LOCALCODEAI_HOME || defaultRoot();
  const manifestPath = path.join(root, 'tools', 'paths.json');
  let manifest = {};
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
      log(`[warn] Tool manifest ${manifestPath} is not a JSON object - falling back to PATH lookups.`);
      manifest = {};
    }
  } catch (e) {
    if (e && e.code === 'ENOENT') {
      log(`[info] No tool manifest at ${manifestPath} - falling back to PATH lookups.`);
    } else {
      log(`[warn] Could not read tool manifest ${manifestPath} (${e.message || e}) - falling back to PATH lookups.`);
    }
    manifest = {};
  }
  // A manifest entry is only trusted if it is actually usable (executables must
  // be executable, scripts readable); a stale entry falls back with a warning
  // instead of failing silently at format time. On Windows there is no
  // meaningful X bit, so existence is the check.
  const usable = (name, p, mode) => {
    if (!p) return false;
    try { fs.accessSync(p, mode); return true; }
    catch { log(`[warn] Tool manifest entry '${name}' (${p}) is missing or not accessible - using fallback.`); return false; }
  };
  const execMode = process.platform === 'win32' ? fs.constants.F_OK : fs.constants.X_OK;
  return {
    root,
    gofumpt: usable('gofumpt', manifest.gofumpt, execMode) ? manifest.gofumpt : 'gofumpt',
    rustfmt: usable('rustfmt', manifest.rustfmt, execMode) ? manifest.rustfmt : 'rustfmt',
    node: usable('node', manifest.node, execMode) ? manifest.node : 'node',
    prettierCli: usable('prettierCli', manifest.prettierCli, fs.constants.R_OK) ? manifest.prettierCli : null,
    pwsh: usable('pwsh', manifest.pwsh, execMode) ? manifest.pwsh : (process.platform === 'win32' ? 'powershell' : 'pwsh'),
    psModulesPath: usable('psModulesPath', manifest.psModulesPath, fs.constants.F_OK) ? manifest.psModulesPath : null
  };
}

// ---------------------------------------------------------------------------
// Child process helper
// ---------------------------------------------------------------------------
function runProc(cmd, args, input, timeoutMs, extraEnv, useShell) {
  return new Promise(resolve => {
    let child;
    const env = Object.assign({}, process.env, extraEnv || {});
    try {
      child = cp.spawn(cmd, args, { env, windowsHide: true, shell: !!useShell });
    } catch (e) {
      resolve({ ok: false, code: -1, stdout: '', stderr: String(e && e.message || e) });
      return;
    }
    let stdout = '', stderr = '', done = false;
    const finish = res => { if (!done) { done = true; resolve(res); } };
    const timer = setTimeout(() => {
      try { child.kill(); } catch { /* ignore */ }
      finish({ ok: false, code: -1, stdout, stderr: stderr + '\n[timeout]' });
    }, timeoutMs || 60000);
    child.on('error', e => { clearTimeout(timer); finish({ ok: false, code: -1, stdout, stderr: String(e.message || e) }); });
    child.stdout.on('data', d => { stdout += d.toString('utf8'); });
    child.stderr.on('data', d => { stderr += d.toString('utf8'); });
    child.on('close', code => {
      clearTimeout(timer);
      finish({ ok: code === 0, code, stdout, stderr });
    });
    if (input !== undefined && input !== null) {
      child.stdin.on('error', () => { /* EPIPE when tool exits early */ });
      child.stdin.write(input, 'utf8');
    }
    child.stdin.end();
  });
}

// ---------------------------------------------------------------------------
// Deterministic formatter pass (stdin -> stdout for every tool)
// ---------------------------------------------------------------------------
async function formatText(langKey, text, fileName, tools, log) {
  const t = 45000;
  let res = null, tool = '';
  if (langKey === 'go') {
    tool = 'gofumpt';
    res = await runProc(tools.gofumpt, [], text, t);
    if (!res.ok) { // fall back to plain gofmt from an installed Go toolchain
      tool = 'gofmt';
      res = await runProc('gofmt', [], text, t);
    }
  } else if (langKey === 'rust') {
    tool = 'rustfmt';
    res = await runProc(tools.rustfmt, ['--edition', '2021'], text, t);
  } else if (langKey === 'javascript') {
    tool = 'prettier';
    if (tools.prettierCli) {
      res = await runProc(tools.node, [tools.prettierCli, '--stdin-filepath', fileName], text, t);
    } else {
      // Last resort: a prettier shim on PATH (needs a shell for .cmd on Windows).
      // Only the basename is passed as the parser hint. Because shell:true
      // interpolates args into a command line, strip every character the shell
      // could interpret (backticks, $, quotes, ...) - the extension survives,
      // which is all prettier needs to pick a parser.
      const hint = '"' + path.basename(fileName).replace(/[^A-Za-z0-9._-]/g, '_') + '"';
      res = await runProc('prettier', ['--stdin-filepath', hint], text, t, null, true);
      if (!res.ok && !res.stderr) res.stderr = 'prettier not found (run the setup script)';
    }
  } else if (langKey === 'powershell') {
    tool = 'Invoke-Formatter';
    const psCmd = '$c=[Console]::In.ReadToEnd();' +
      'if($env:LCAI_PSMODULES){$env:PSModulePath=$env:LCAI_PSMODULES+[IO.Path]::PathSeparator+$env:PSModulePath};' +
      'Import-Module PSScriptAnalyzer -ErrorAction Stop;' +
      '[Console]::Out.Write((Invoke-Formatter -ScriptDefinition $c))';
    const extraEnv = tools.psModulesPath ? { LCAI_PSMODULES: tools.psModulesPath } : {};
    res = await runProc(tools.pwsh, ['-NoProfile', '-NonInteractive', '-Command', psCmd], text, t, extraEnv);
    if (!res.ok && process.platform === 'win32' && tools.pwsh !== 'powershell') {
      res = await runProc('powershell', ['-NoProfile', '-NonInteractive', '-Command', psCmd], text, t, extraEnv);
    }
  }
  if (res && res.ok && res.stdout && res.stdout.trim().length > 0) {
    return { text: res.stdout, applied: true, tool };
  }
  const why = res ? (res.stderr || `exit ${res.code}`).trim().split('\n')[0] : 'no formatter';
  log(`[format] ${tool} skipped for ${fileName}: ${why}`);
  return { text, applied: false, tool };
}

// ---------------------------------------------------------------------------
// LLM pass via Ollama /api/chat
// ---------------------------------------------------------------------------
function buildSystemPrompt(langKey) {
  const L = LANGS[langKey];
  return [
    `You are an expert ${L.name} developer performing a conservative refactor of one source file.`,
    'Rules:',
    '- Preserve behavior, public APIs, signatures, exports and side effects EXACTLY. Never delete functionality.',
    `- Improve readability, naming, structure and ${L.name} idioms where it is safe.`,
    `- Clean up comments: fix grammar and spelling, remove noise comments, and normalize doc comments to ${L.docStyle}. Keep TODO/FIXME markers.`,
    '- Do not add new dependencies, imports of external packages, or new files.',
    '- If the file is already clean, return it unchanged.',
    '- Output ONLY the complete final file content. No markdown fences. No explanations. The first line of the user message is the file path for context only - do not include it in the output.'
  ].join('\n');
}

// The model is told to output raw file content, but models often wrap it in a
// markdown fence anyway, sometimes with prose around it. Unwrap conservatively:
// a response that IS one fenced block loses the fences; a response with prose
// around a fence keeps only the fenced content when it is clearly the payload
// (at least half the response). Anything else is returned as-is - llmRefactor's
// suspiciously-short guard backstops mangled cases.
function stripFences(s) {
  const t = s.replace(/^\uFEFF/, '').trim();
  if (t.startsWith('```')) {
    const nl = t.indexOf('\n');
    let body = nl >= 0 ? t.slice(nl + 1) : '';
    if (body.endsWith('```')) body = body.slice(0, -3).replace(/\r?\n$/, '');
    return body;
  }
  const fenced = [];
  const re = /```[^\n]*\n([\s\S]*?)```/g;
  for (let m = re.exec(t); m !== null; m = re.exec(t)) fenced.push(m[1]);
  if (fenced.length) {
    const biggest = fenced.reduce((a, b) => (b.length > a.length ? b : a));
    if (biggest.length >= t.length / 2) return biggest.replace(/\r?\n$/, '');
  }
  return t;
}

async function llmRefactor(langKey, text, fileName, cfg, log) {
  const body = {
    model: cfg.model,
    stream: false,
    options: { temperature: cfg.temperature },
    messages: [
      { role: 'system', content: buildSystemPrompt(langKey) },
      { role: 'user', content: `Path: ${fileName}\n\n${text}` }
    ]
  };
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), cfg.timeoutSeconds * 1000);
  let resp, data;
  try {
    resp = await fetch(`${cfg.endpoint}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: ctrl.signal
    });
  } catch (e) {
    clearTimeout(timer);
    const msg = e && e.name === 'AbortError' ? `timed out after ${cfg.timeoutSeconds}s` : `Ollama not reachable at ${cfg.endpoint} (${e.message || e}). Is 'ollama serve' running?`;
    return { text: null, reason: msg };
  }
  clearTimeout(timer);
  if (!resp.ok) {
    const errTxt = (await resp.text().catch(() => '')).slice(0, 300);
    return { text: null, reason: `HTTP ${resp.status} from Ollama: ${errTxt}` };
  }
  try { data = await resp.json(); } catch { return { text: null, reason: 'invalid JSON from Ollama' }; }
  let out = data && data.message && typeof data.message.content === 'string' ? data.message.content : '';
  out = stripFences(out);
  if (!out.trim()) return { text: null, reason: 'model returned empty output' };
  // Safety guard: refuse truncated/mangled outputs.
  if (text.length > 400 && out.length < text.length * 0.4) {
    return { text: null, reason: `output suspiciously short (${out.length} vs ${text.length} chars) - kept original` };
  }
  // Preserve the original trailing-newline convention.
  if (text.endsWith('\n') && !out.endsWith('\n')) out += '\n';
  return { text: out, reason: null };
}

// ---------------------------------------------------------------------------
// Per-file pipeline
// ---------------------------------------------------------------------------
async function processText(langKey, original, fileName, cfg, tools, log) {
  const result = { finalText: original, formatterApplied: false, llmApplied: false, skippedLLM: null, error: null };
  const f1 = await formatText(langKey, original, fileName, tools, log);
  result.finalText = f1.text;
  result.formatterApplied = f1.applied;

  const kb = Buffer.byteLength(result.finalText, 'utf8') / 1024;
  if (cfg.llmPass && kb <= cfg.maxFileKB) {
    const l = await llmRefactor(langKey, result.finalText, fileName, cfg, log);
    if (l.text !== null) {
      const f2 = await formatText(langKey, l.text, fileName, tools, log); // re-normalize LLM output
      result.finalText = f2.text;
      result.llmApplied = true;
    } else {
      result.skippedLLM = l.reason;
      log(`[llm] ${fileName}: ${l.reason}`);
    }
  } else if (cfg.llmPass) {
    result.skippedLLM = `file is ${Math.round(kb)} KB > localCodeAI.maxFileKB (${cfg.maxFileKB}) - formatter only`;
    log(`[llm] ${fileName}: ${result.skippedLLM}`);
  }
  return result;
}

// A single LLM pass can take minutes on CPU with no visible activity. Cycle the
// progress notification through the words in progress.txt, growing a trail of
// dots one at a time (up to 6) before moving to the next word, so the user
// sees something happening. Returns a function that stops the heartbeat.
function startHeartbeat(progress, baseMessage) {
  const words = loadProgressWords();
  let word = 0, dots = 0;
  const timer = setInterval(() => {
    dots++;
    if (dots > 6) { dots = 0; word = (word + 1) % words.length; }
    progress.report({ message: `${baseMessage} - ${words[word]}${'.'.repeat(dots)}` });
  }, 2000);
  return () => clearInterval(timer);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------
async function cmdCurrentFile(log) {
  const editor = vscode.window.activeTextEditor;
  if (!editor) { vscode.window.showInformationMessage('Local Code AI: no active editor.'); return; }
  const doc = editor.document;
  const langKey = languageForFile(doc.fileName);
  if (!langKey) {
    vscode.window.showInformationMessage('Local Code AI: unsupported file type (supported: Go, PowerShell, Rust, JavaScript).');
    return;
  }
  const cfg = getConfig();
  const tools = loadToolPaths(cfg, log);
  const original = doc.getText();

  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `Local Code AI: ${path.basename(doc.fileName)}`, cancellable: false },
    async progress => {
      progress.report({ message: 'formatting + refactoring...' });
      const stopHeartbeat = startHeartbeat(progress, 'formatting + refactoring...');
      const versionBefore = doc.version;
      let r;
      try { r = await processText(langKey, original, doc.fileName, cfg, tools, log); }
      finally { stopHeartbeat(); }
      if (r.finalText === original) {
        vscode.window.showInformationMessage('Local Code AI: no changes needed.');
        return;
      }
      // The document may have been edited while the pipeline ran; replacing it
      // then would throw away those keystrokes. Bail out instead.
      if (doc.isClosed || doc.version !== versionBefore) {
        vscode.window.showWarningMessage('Local Code AI: file changed while processing - result discarded, run again.');
        return;
      }
      const edit = new vscode.WorkspaceEdit();
      const fullRange = new vscode.Range(doc.positionAt(0), doc.positionAt(original.length));
      edit.replace(doc.uri, fullRange, r.finalText);
      const applied = await vscode.workspace.applyEdit(edit);
      if (applied) {
        await doc.save(); // auto-apply: save, never commit
        const bits = [];
        if (r.formatterApplied) bits.push('formatted');
        if (r.llmApplied) bits.push('LLM-refactored');
        if (r.skippedLLM) bits.push(`LLM skipped: ${r.skippedLLM}`);
        vscode.window.showInformationMessage(`Local Code AI: saved (${bits.join(', ') || 'changed'}).`);
      } else {
        vscode.window.showErrorMessage('Local Code AI: could not apply edit.');
      }
    });
}

async function collectWorkspaceFiles(cfg) {
  const exclude = cfg.excludeGlobs.length ? `{${cfg.excludeGlobs.join(',')}}` : undefined;
  const seen = new Map();
  for (const key of Object.keys(LANGS)) {
    const uris = await vscode.workspace.findFiles(LANGS[key].glob, exclude);
    for (const u of uris) {
      if (!seen.has(u.fsPath)) seen.set(u.fsPath, { uri: u, langKey: key });
    }
  }
  return [...seen.values()].sort((a, b) => a.uri.fsPath.localeCompare(b.uri.fsPath));
}

async function cmdWorkspace(log, channel) {
  if (!vscode.workspace.workspaceFolders || vscode.workspace.workspaceFolders.length === 0) {
    vscode.window.showInformationMessage('Local Code AI: open a folder or workspace first.');
    return;
  }
  const cfg = getConfig();
  const tools = loadToolPaths(cfg, log);
  const files = await collectWorkspaceFiles(cfg);
  if (files.length === 0) {
    vscode.window.showInformationMessage('Local Code AI: no Go / PowerShell / Rust / JavaScript files found (check localCodeAI.excludeGlobs).');
    return;
  }
  // Confirmation threshold (default 50) - configurable via localCodeAI.maxFilesBeforeWarning.
  if (files.length > cfg.maxFilesBeforeWarning) {
    const pick = await vscode.window.showWarningMessage(
      `Local Code AI is about to modify up to ${files.length} files in place (auto-save, no git commit). ` +
      `Threshold is ${cfg.maxFilesBeforeWarning} (setting: localCodeAI.maxFilesBeforeWarning). Continue?`,
      { modal: true }, 'Proceed');
    if (pick !== 'Proceed') { log('[run] cancelled by user at file-count warning.'); return; }
  }
  await vscode.workspace.saveAll(false); // flush dirty editors so disk is the source of truth

  const tally = { changed: 0, llm: 0, formatted: 0, unchanged: 0, errors: 0, skipped: 0 };
  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: 'Local Code AI: workspace run', cancellable: true },
    async (progress, token) => {
      for (let i = 0; i < files.length; i++) {
        if (token.isCancellationRequested) { log('[run] cancelled.'); break; }
        const { uri, langKey } = files[i];
        const rel = vscode.workspace.asRelativePath(uri);
        progress.report({ message: `${i + 1}/${files.length}  ${rel}`, increment: 100 / files.length });
        const stopHeartbeat = startHeartbeat(progress, `${i + 1}/${files.length}  ${rel}`);
        try {
          const stat = await fsp.stat(uri.fsPath);
          if (stat.size > 2 * 1024 * 1024) { tally.skipped++; log(`[skip] ${rel}: > 2 MB`); continue; }
          const original = await fsp.readFile(uri.fsPath, 'utf8');
          if (original.includes('\u0000')) { tally.skipped++; log(`[skip] ${rel}: looks binary`); continue; }
          const r = await processText(langKey, original, uri.fsPath, cfg, tools, log);
          if (r.finalText !== original) {
            // The LLM pass can take minutes. If the file gained unsaved editor
            // changes or was modified/deleted on disk meanwhile, writing would
            // clobber the newer content - skip it instead.
            const dirty = vscode.workspace.textDocuments.some(d => d.uri.fsPath === uri.fsPath && d.isDirty);
            const current = await fsp.readFile(uri.fsPath, 'utf8').catch(() => null);
            if (dirty || current !== original) {
              tally.skipped++;
              log(`[skip] ${rel}: changed while being processed - not overwritten`);
              continue;
            }
            await fsp.writeFile(uri.fsPath, r.finalText, 'utf8');
            tally.changed++;
            if (r.llmApplied) tally.llm++; else tally.formatted++;
            log(`[ok]   ${rel}${r.llmApplied ? ' (formatter+LLM)' : ' (formatter)'}`);
          } else {
            tally.unchanged++;
            log(`[same] ${rel}`);
          }
        } catch (e) {
          tally.errors++;
          log(`[err]  ${rel}: ${e.message || e}`);
        } finally {
          stopHeartbeat();
        }
      }
    });
  const summary = `Local Code AI: ${tally.changed} file(s) changed & saved ` +
    `(${tally.llm} with LLM, ${tally.formatted} formatter-only), ${tally.unchanged} unchanged, ` +
    `${tally.skipped} skipped, ${tally.errors} error(s).`;
  log(`[done] ${summary}`);
  if (tally.errors > 0) channel.show(true);
  vscode.window.showInformationMessage(summary);
}

async function cmdCheckSetup(log, channel) {
  const cfg = getConfig();
  const tools = loadToolPaths(cfg, log);
  channel.show(true);
  log('--- Local Code AI setup check ---');
  log(`Tools root: ${tools.root}`);
  try {
    const r = await fetch(`${cfg.endpoint}/api/version`);
    log(`Ollama at ${cfg.endpoint}: ${r.ok ? 'OK ' + JSON.stringify(await r.json()) : 'HTTP ' + r.status}`);
    const tags = await (await fetch(`${cfg.endpoint}/api/tags`)).json();
    const names = (tags.models || []).map(m => m.name);
    const found = names.some(n => n === cfg.model || n.startsWith(cfg.model + ':'));
    log(`Model '${cfg.model}': ${found ? 'available' : 'NOT FOUND. Available: ' + names.join(', ')}`);
  } catch (e) {
    log(`Ollama at ${cfg.endpoint}: NOT REACHABLE (${e.message || e}). Run the setup script or start 'ollama serve'.`);
  }
  const probes = [
    ['gofumpt', tools.gofumpt, ['--version'], null],
    ['rustfmt', tools.rustfmt, ['--version'], null],
    ['node', tools.node, ['--version'], null],
    ['pwsh/PSScriptAnalyzer', tools.pwsh, ['-NoProfile', '-NonInteractive', '-Command',
      'if($env:LCAI_PSMODULES){$env:PSModulePath=$env:LCAI_PSMODULES+[IO.Path]::PathSeparator+$env:PSModulePath};' +
      '(Get-Module PSScriptAnalyzer -ListAvailable | Select-Object -First 1).Version.ToString()'],
      tools.psModulesPath ? { LCAI_PSMODULES: tools.psModulesPath } : null]
  ];
  for (const [label, cmd, args, env] of probes) {
    const r = await runProc(cmd, args, null, 20000, env || {});
    log(`${label}: ${r.ok ? (r.stdout.trim().split('\n')[0] || 'OK') : 'MISSING/FAILED (' + (r.stderr.trim().split('\n')[0] || 'exit ' + r.code) + ')'}`);
  }
  if (tools.prettierCli) {
    const r = await runProc(tools.node, [tools.prettierCli, '--version'], null, 20000);
    log(`prettier: ${r.ok ? r.stdout.trim() : 'MISSING/FAILED'}`);
  } else {
    log('prettier: no manifest entry - will try PATH at run time.');
  }
  log('--- end check ---');
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------
function activate(context) {
  const channel = vscode.window.createOutputChannel('Local Code AI');
  const log = msg => channel.appendLine(`[${new Date().toISOString().slice(11, 19)}] ${msg}`);
  if (typeof fetch !== 'function') {
    vscode.window.showErrorMessage('Local Code AI requires VS Code 1.85+ (built-in fetch).');
    return;
  }
  const chatProvider = new ChatViewProvider(getConfig, log);
  const openInEditor = () => ChatPanel.createOrShow(getConfig, log);
  const openInSidebar = () => vscode.commands.executeCommand('localCodeAI.chatView.focus');
  context.subscriptions.push(
    channel,
    vscode.window.registerWebviewViewProvider('localCodeAI.chatView', chatProvider,
      { webviewOptions: { retainContextWhenHidden: true } }),
    // Restore a chat tab that was open when the window was reloaded.
    vscode.window.registerWebviewPanelSerializer(PANEL_TYPE, {
      async deserializeWebviewPanel(panel) { ChatPanel.adopt(panel, getConfig, log); }
    }),
    vscode.commands.registerCommand('localCodeAI.openChat',
      () => (getConfig().chatOpenIn === 'sidebar' ? openInSidebar() : openInEditor())),
    vscode.commands.registerCommand('localCodeAI.openChatInEditor', openInEditor),
    vscode.commands.registerCommand('localCodeAI.openChatInSidebar', openInSidebar),
    vscode.commands.registerCommand('localCodeAI.refactorCurrentFile', () => cmdCurrentFile(log).catch(e => { log('[fatal] ' + (e.stack || e)); vscode.window.showErrorMessage('Local Code AI: ' + (e.message || e)); })),
    vscode.commands.registerCommand('localCodeAI.refactorWorkspace', () => cmdWorkspace(log, channel).catch(e => { log('[fatal] ' + (e.stack || e)); vscode.window.showErrorMessage('Local Code AI: ' + (e.message || e)); })),
    vscode.commands.registerCommand('localCodeAI.checkSetup', () => cmdCheckSetup(log, channel).catch(e => log('[fatal] ' + (e.stack || e))))
  );
}

function deactivate() { }

module.exports = { activate, deactivate };
