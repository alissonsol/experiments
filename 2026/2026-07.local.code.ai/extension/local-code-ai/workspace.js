// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Local Code AI - workspace awareness for the chat.
// Two things live here:
//   1. buildContextBlock() - a snapshot of the open project (folders, file tree,
//      open tabs, active editor, diagnostics) appended to the chat system prompt.
//   2. TOOL_SPECS / runTool() - read-only tools the model can call to list, read
//      and search the project itself instead of asking the user to paste code.
// Everything is confined to the open workspace folders: paths outside them are
// rejected, and nothing here ever writes.
'use strict';

const vscode = require('vscode');
const path = require('path');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function folders() {
  return vscode.workspace.workspaceFolders || [];
}

function excludeGlob(cfg) {
  const globs = cfg.excludeGlobs || [];
  return globs.length ? `{${globs.join(',')}}` : undefined;
}

// Resolve a model-supplied path (relative to a workspace folder, or absolute)
// and refuse anything that escapes the workspace.
function resolveInWorkspace(p) {
  if (!p || typeof p !== 'string') throw new Error('path is required');
  const roots = folders();
  if (roots.length === 0) throw new Error('no folder is open in VS Code');

  const candidates = [];
  if (path.isAbsolute(p)) {
    candidates.push(vscode.Uri.file(path.normalize(p)));
  } else {
    // "folderName/rest" first (multi-root), then plain relative in every root.
    const [head, ...rest] = p.split(/[\\/]/);
    for (const root of roots) {
      if (root.name === head && rest.length) candidates.push(vscode.Uri.joinPath(root.uri, ...rest));
      candidates.push(vscode.Uri.joinPath(root.uri, ...p.split(/[\\/]/)));
    }
  }
  for (const uri of candidates) {
    const owner = roots.find(r => {
      const rel = path.relative(r.uri.fsPath, uri.fsPath);
      return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
    });
    if (owner) return uri;
  }
  throw new Error(`'${p}' is outside the open workspace folders`);
}

// Prefer the in-memory document so unsaved editor changes are what the model sees.
async function readText(uri, maxBytes) {
  const open = vscode.workspace.textDocuments.find(d => d.uri.toString() === uri.toString());
  if (open) return { text: open.getText(), dirty: open.isDirty };
  const bytes = await vscode.workspace.fs.readFile(uri);
  if (bytes.byteLength > maxBytes) {
    const head = Buffer.from(bytes.slice(0, maxBytes)).toString('utf8');
    return { text: head, dirty: false, truncated: true, totalBytes: bytes.byteLength };
  }
  const text = Buffer.from(bytes).toString('utf8');
  if (text.includes('\u0000')) throw new Error('file looks binary');
  return { text, dirty: false };
}

function rel(uri) {
  return vscode.workspace.asRelativePath(uri, folders().length > 1);
}

function severityName(s) {
  return ['Error', 'Warning', 'Info', 'Hint'][s] || 'Unknown';
}

// ---------------------------------------------------------------------------
// Context snapshot (rebuilt for every request - the project moves under us)
// ---------------------------------------------------------------------------
async function buildContextBlock(cfg, opts) {
  const roots = folders();
  if (roots.length === 0) {
    return 'WORKSPACE: no folder is currently open in VS Code. Only the text the user pastes is available.';
  }
  const lines = ['# Workspace context (live, from VS Code)', ''];

  lines.push('## Folders open');
  for (const r of roots) lines.push(`- ${r.name} -> ${r.uri.fsPath}`);
  lines.push('');

  if (opts.includeTree !== false) {
    const limit = cfg.chatContextFileLimit;
    const uris = await vscode.workspace.findFiles('**/*', excludeGlob(cfg), limit + 1);
    const paths = uris.slice(0, limit).map(rel).sort();
    lines.push(`## Files (${uris.length > limit ? `first ${limit}, more exist` : paths.length} total)`);
    for (const p of paths) lines.push(`- ${p}`);
    if (uris.length > limit) lines.push(`- ... truncated at ${limit}; use the list_files tool with a glob to see more.`);
    lines.push('');
  }

  const tabs = [];
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      const input = tab.input;
      if (input && input.uri) tabs.push(`${rel(input.uri)}${tab.isDirty ? ' (unsaved changes)' : ''}${tab.isActive ? ' (active)' : ''}`);
    }
  }
  if (tabs.length) {
    lines.push('## Open editors');
    for (const t of tabs) lines.push(`- ${t}`);
    lines.push('');
  }

  const editor = vscode.window.activeTextEditor;
  if (editor) {
    const sel = editor.selection;
    lines.push('## Active editor');
    lines.push(`- ${rel(editor.document.uri)} (${editor.document.languageId}, ${editor.document.lineCount} lines)`);
    lines.push(`- cursor on line ${sel.active.line + 1}${sel.isEmpty ? '' : `, selection lines ${sel.start.line + 1}-${sel.end.line + 1}`}`);
    lines.push('');
  }

  const all = vscode.languages.getDiagnostics();
  let errors = 0, warnings = 0;
  for (const [, diags] of all) {
    for (const d of diags) {
      if (d.severity === vscode.DiagnosticSeverity.Error) errors++;
      else if (d.severity === vscode.DiagnosticSeverity.Warning) warnings++;
    }
  }
  lines.push(`## Problems: ${errors} error(s), ${warnings} warning(s) (use get_diagnostics for details)`);
  lines.push('');
  lines.push('The files above are REAL and readable with the tools you have. Never ask the user to');
  lines.push('paste code that you can read yourself - call read_file / search_text / list_files instead.');
  return lines.join('\n');
}

// Text of specific attachments the user ticked or picked, for the user message.
async function buildAttachments(cfg, opts, uris) {
  const parts = [];
  const notes = [];
  const maxBytes = cfg.chatMaxReadKB * 1024;

  const editor = vscode.window.activeTextEditor;
  if (opts.includeSelection && editor && !editor.selection.isEmpty) {
    const sel = editor.selection;
    parts.push(`Selected text in ${rel(editor.document.uri)} (lines ${sel.start.line + 1}-${sel.end.line + 1}):\n\`\`\`${editor.document.languageId}\n${editor.document.getText(sel)}\n\`\`\``);
    notes.push(`selection from ${path.basename(editor.document.fileName)}`);
  }
  if (opts.includeActiveFile && editor) {
    const text = editor.document.getText().slice(0, maxBytes);
    parts.push(`Contents of ${rel(editor.document.uri)}:\n\`\`\`${editor.document.languageId}\n${text}\n\`\`\``);
    notes.push(path.basename(editor.document.fileName));
  } else if (opts.includeActiveFile) {
    notes.push('no active editor');
  }
  for (const uri of uris || []) {
    try {
      const r = await readText(uri, maxBytes);
      parts.push(`Contents of ${rel(uri)}:\n\`\`\`\n${r.text}\n\`\`\``);
      notes.push(rel(uri));
    } catch (e) {
      notes.push(`${rel(uri)} (unreadable: ${e.message || e})`);
    }
  }
  return { text: parts.join('\n\n'), notes };
}

// ---------------------------------------------------------------------------
// Tools the model can call (read-only, workspace-scoped)
// ---------------------------------------------------------------------------
const TOOL_SPECS = [
  {
    type: 'function',
    function: {
      name: 'list_files',
      description: 'List files in the open VS Code workspace. Use a glob to narrow it, e.g. "**/*.go".',
      parameters: {
        type: 'object',
        properties: {
          glob: { type: 'string', description: 'Glob relative to the workspace, default "**/*".' },
          limit: { type: 'number', description: 'Maximum paths to return (default 200).' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Read a file from the open workspace. Returns numbered lines. Unsaved editor changes are included.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Workspace-relative path, as shown by list_files.' },
          start_line: { type: 'number', description: '1-based first line (optional).' },
          end_line: { type: 'number', description: '1-based last line (optional).' }
        },
        required: ['path']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'search_text',
      description: 'Search the workspace for a string or regular expression. Returns matching file:line entries.',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Text or regular expression to find.' },
          is_regex: { type: 'boolean', description: 'Treat query as a regular expression (default false).' },
          glob: { type: 'string', description: 'Restrict to files matching this glob (default "**/*").' },
          max_results: { type: 'number', description: 'Maximum matches to return (default 60).' }
        },
        required: ['query']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_diagnostics',
      description: 'List current problems (errors, warnings) reported by VS Code language servers.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Limit to one workspace-relative file (optional).' }
        },
        required: []
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'get_active_editor',
      description: 'Return the path, language, selection and full text of the file the user is currently looking at.',
      parameters: { type: 'object', properties: {}, required: [] }
    }
  }
];

async function toolListFiles(args, cfg) {
  const limit = Math.min(Math.max(Number(args.limit) || 200, 1), 2000);
  const uris = await vscode.workspace.findFiles(args.glob || '**/*', excludeGlob(cfg), limit + 1);
  const paths = uris.slice(0, limit).map(rel).sort();
  if (!paths.length) return `No files match ${args.glob || '**/*'} (excludes: ${(cfg.excludeGlobs || []).join(', ') || 'none'}).`;
  const more = uris.length > limit ? `\n... truncated at ${limit} results.` : '';
  return paths.join('\n') + more;
}

async function toolReadFile(args, cfg) {
  const uri = resolveInWorkspace(args.path);
  const r = await readText(uri, cfg.chatMaxReadKB * 1024);
  let lines = r.text.split('\n');
  const from = Math.max(Number(args.start_line) || 1, 1);
  const to = Math.min(Number(args.end_line) || lines.length, lines.length);
  lines = lines.slice(from - 1, to);
  const numbered = lines.map((l, i) => `${from + i}\t${l}`).join('\n');
  const flags = [];
  if (r.dirty) flags.push('unsaved editor changes included');
  if (r.truncated) flags.push(`truncated to ${cfg.chatMaxReadKB} KB of ${Math.round(r.totalBytes / 1024)} KB`);
  return `${rel(uri)}${flags.length ? ` (${flags.join('; ')})` : ''}\n${numbered}`;
}

async function toolSearchText(args, cfg) {
  const max = Math.min(Math.max(Number(args.max_results) || 60, 1), 500);
  let rx;
  try {
    rx = new RegExp(args.is_regex ? args.query : args.query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g');
  } catch (e) {
    return `Invalid regular expression: ${e.message || e}`;
  }
  const uris = await vscode.workspace.findFiles(args.glob || '**/*', excludeGlob(cfg), 3000);
  const hits = [];
  for (const uri of uris) {
    if (hits.length >= max) break;
    let text;
    try {
      const r = await readText(uri, 512 * 1024);
      text = r.text;
    } catch { continue; }
    if (text.includes('\u0000')) continue;
    const lines = text.split('\n');
    for (let i = 0; i < lines.length && hits.length < max; i++) {
      rx.lastIndex = 0;
      if (rx.test(lines[i])) hits.push(`${rel(uri)}:${i + 1}: ${lines[i].trim().slice(0, 200)}`);
    }
  }
  if (!hits.length) return `No matches for ${args.query}.`;
  return hits.join('\n') + (hits.length >= max ? `\n... stopped at ${max} matches.` : '');
}

async function toolGetDiagnostics(args) {
  const entries = args.path
    ? [[resolveInWorkspace(args.path), vscode.languages.getDiagnostics(resolveInWorkspace(args.path))]]
    : vscode.languages.getDiagnostics();
  const out = [];
  for (const [uri, diags] of entries) {
    for (const d of diags) {
      out.push(`${rel(uri)}:${d.range.start.line + 1}: [${severityName(d.severity)}] ${d.message.split('\n')[0]}${d.source ? ` (${d.source})` : ''}`);
    }
  }
  if (!out.length) return 'No problems reported.';
  return out.slice(0, 200).join('\n') + (out.length > 200 ? `\n... ${out.length - 200} more.` : '');
}

async function toolGetActiveEditor(_args, cfg) {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return 'No editor is active right now.';
  const doc = editor.document;
  const sel = editor.selection;
  const text = doc.getText().slice(0, cfg.chatMaxReadKB * 1024);
  return [
    `path: ${rel(doc.uri)}`,
    `language: ${doc.languageId}`,
    `lines: ${doc.lineCount}${doc.isDirty ? ' (unsaved changes)' : ''}`,
    sel.isEmpty ? `cursor: line ${sel.active.line + 1}` : `selection: lines ${sel.start.line + 1}-${sel.end.line + 1}`,
    '',
    text
  ].join('\n');
}

const TOOL_IMPLS = {
  list_files: toolListFiles,
  read_file: toolReadFile,
  search_text: toolSearchText,
  get_diagnostics: toolGetDiagnostics,
  get_active_editor: toolGetActiveEditor
};

// Never throws: a tool failure is fed back to the model as text so it can recover.
async function runTool(name, args, cfg) {
  const impl = TOOL_IMPLS[name];
  if (!impl) return `Error: unknown tool '${name}'. Available: ${Object.keys(TOOL_IMPLS).join(', ')}.`;
  try {
    const result = await impl(args || {}, cfg);
    const cap = cfg.chatMaxReadKB * 1024;
    return result.length > cap ? result.slice(0, cap) + '\n... [truncated]' : result;
  } catch (e) {
    return `Error from ${name}: ${e.message || e}`;
  }
}

// One-line summary for the chat transcript, so the user sees what was read.
function describeCall(name, args) {
  const a = args || {};
  if (name === 'read_file') return `read ${a.path}${a.start_line ? ` (lines ${a.start_line}-${a.end_line || 'end'})` : ''}`;
  if (name === 'list_files') return `list ${a.glob || '**/*'}`;
  if (name === 'search_text') return `search ${JSON.stringify(a.query)}${a.glob ? ` in ${a.glob}` : ''}`;
  if (name === 'get_diagnostics') return `problems${a.path ? ` in ${a.path}` : ''}`;
  if (name === 'get_active_editor') return 'active editor';
  return name;
}

module.exports = { buildContextBlock, buildAttachments, TOOL_SPECS, runTool, describeCall, resolveInWorkspace };
