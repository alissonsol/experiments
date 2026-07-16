// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Local Code AI - Ollama server + model lifecycle.
// The Ollama server is an EXTERNAL process, deliberately not tied to any one
// VS Code window: every window (and the terminal) shares the server at the
// configured endpoint, and closing VS Code leaves it running. This module adds
// visibility and control on top: probes for activation and "Check Setup", a
// detached "Start Model" spawn, and "Stop Model" unload/shutdown so the model
// is not holding GPU/RAM when nobody wants it. Ollama itself evicts an idle
// model after ~5 minutes by default; Stop Model frees the memory immediately.
'use strict';

const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function defaultRoot() {
  if (process.platform === 'win32') return 'C:\\LocalCodeAI';
  return path.join(os.homedir(), 'LocalCodeAI');
}

function installRoot(cfg) {
  return cfg.toolsRoot || process.env.LOCALCODEAI_HOME || defaultRoot();
}

async function fetchJson(url, init, timeoutMs) {
  const resp = await fetch(url, { ...(init || {}), signal: AbortSignal.timeout(timeoutMs || 3000) });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  return resp.json();
}

// GET /api/version - is the server up at all?
async function probeServer(endpoint) {
  try {
    const v = await fetchJson(`${endpoint}/api/version`);
    return { up: true, version: (v && v.version) || '?' };
  } catch (e) {
    return { up: false, error: e.message || String(e) };
  }
}

// GET /api/tags - is the model (or alias) present in the store? Throws when
// the server itself is unreachable; probe the server first.
async function probeModel(endpoint, model) {
  const tags = await fetchJson(`${endpoint}/api/tags`);
  const names = (tags.models || []).map(m => m.name);
  const found = names.some(n => n === model || n.startsWith(model + ':'));
  return { found, names };
}

// GET /api/ps - which models are loaded in memory right now?
async function loadedModels(endpoint) {
  const ps = await fetchJson(`${endpoint}/api/ps`);
  return (ps.models || []).map(m => m.name);
}

// POST /api/show - cheap usability signal: reads the model's manifest without
// loading weights, so a broken alias (deleted blob, removed base model)
// surfaces without paying a multi-GB load.
async function showModel(endpoint, model) {
  await fetchJson(`${endpoint}/api/show`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model })
  }, 10000);
}

// host:port when the endpoint is on this machine, null otherwise. Start/Stop
// Model manage local processes only - spawning or taskkilling for a remote
// endpoint would start an orphan server here or kill an unrelated install.
function localHostPort(endpoint) {
  try {
    const u = new URL(endpoint);
    const host = u.hostname.toLowerCase();
    if (!['127.0.0.1', 'localhost', '::1'].includes(host)) return null;
    return `${u.hostname}:${u.port || '11434'}`;
  } catch { return null; }
}

// Load the model into memory (empty /api/generate) so the first real prompt
// does not pay the load time. Returns milliseconds taken, or throws.
async function loadModel(endpoint, model, timeoutMs) {
  const t0 = Date.now();
  await fetchJson(`${endpoint}/api/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, stream: false })
  }, timeoutMs || 180000);
  return Date.now() - t0;
}

// Evict the model from memory now (keep_alive 0); the server keeps running and
// the next prompt just pays the load time again. The unload request returns
// before the eviction lands in /api/ps (~1-2s later), so poll until the model
// is really gone. Returns true when eviction was observed; false when the
// model is still resident after ~10s (e.g. another client has a generation in
// flight) - callers must not claim the memory was freed in that case.
async function unloadModel(endpoint, model) {
  await fetchJson(`${endpoint}/api/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, stream: false, keep_alive: 0 })
  }, 60000);
  for (let i = 0; i < 10; i++) {
    let loaded;
    try { loaded = await loadedModels(endpoint); }
    catch { return true; } // server gone mid-poll: nothing is resident anymore
    if (!loaded.some(n => n === model || n.startsWith(model + ':'))) return true;
    await new Promise(r => setTimeout(r, 1000));
  }
  return false;
}

// Resolve the ollama executable: explicit setting, then the platform's known
// install locations (VS Code's PATH often predates the setup run), then PATH.
function findOllama(cfg) {
  const candidates = [];
  if (cfg.ollamaPath) candidates.push(cfg.ollamaPath);
  const root = installRoot(cfg);
  if (process.platform === 'win32') {
    candidates.push(
      path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Ollama', 'ollama.exe'),
      'C:\\Program Files\\Ollama\\ollama.exe'
    );
  } else {
    candidates.push(
      '/opt/homebrew/bin/ollama', '/usr/local/bin/ollama', '/usr/bin/ollama',
      path.join(root, 'tools', 'ollama', 'bin', 'ollama'),
      path.join(root, 'tools', 'ollama', 'ollama')
    );
  }
  for (const c of candidates) {
    if (!c) continue;
    try { fs.accessSync(c, fs.constants.F_OK); return c; } catch { /* try next */ }
  }
  return 'ollama'; // PATH fallback; spawn surfaces ENOENT if that fails too
}

// The setup script's model store, but only when it was actually populated: an
// empty <root>/models (e.g. a -KeepExistingOllamaModelPath install) must not
// hijack OLLAMA_MODELS away from Ollama's default store.
function setupModelStore(cfg) {
  const store = path.join(installRoot(cfg), 'models');
  try { fs.accessSync(path.join(store, 'manifests'), fs.constants.F_OK); return store; }
  catch { return null; }
}

// Windows env vars are case-insensitive but a spread of process.env is a plain
// case-sensitive object; find the key as the OS would.
function envKey(env, name) {
  return Object.keys(env).find(k => k.toUpperCase() === name.toUpperCase());
}

// Spawn 'ollama serve' fully detached: stdio 'ignore' (a detached child that
// inherits the parent's pipes outlives VS Code and pins them - the detached-
// grandchild trap), no console window, unref'ed so the extension host never
// waits on it. The server outlives every VS Code window by design.
function spawnServer(cfg, log) {
  const bin = findOllama(cfg);
  const env = { ...process.env };
  if (!envKey(env, 'OLLAMA_MODELS')) {
    const store = setupModelStore(cfg);
    if (store) env.OLLAMA_MODELS = store; // this VS Code may predate the setup run's user-env change
  }
  // Serve exactly what the extension will probe: bind the configured endpoint,
  // not whatever a stray OLLAMA_HOST in the inherited env happens to say.
  const hostPort = localHostPort(cfg.endpoint);
  if (hostPort) {
    const stray = envKey(env, 'OLLAMA_HOST');
    if (stray) delete env[stray];
    env.OLLAMA_HOST = hostPort;
  }
  return new Promise(resolve => {
    let child;
    try {
      child = cp.spawn(bin, ['serve'], { detached: true, stdio: 'ignore', windowsHide: true, env });
    } catch (e) {
      resolve({ ok: false, error: `could not start '${bin}': ${e.message || e}` });
      return;
    }
    let settled = false;
    child.on('error', e => {
      if (!settled) { settled = true; resolve({ ok: false, error: `could not start '${bin}': ${e.message || e}` }); }
    });
    // spawn errors (ENOENT) arrive on the next ticks; give them a moment.
    setTimeout(() => {
      if (!settled) {
        settled = true;
        child.unref();
        log(`[model] spawned '${bin} serve' (pid ${child.pid}${env.OLLAMA_MODELS ? `, OLLAMA_MODELS=${env.OLLAMA_MODELS}` : ''})`);
        resolve({ ok: true, bin });
      }
    }, 400);
  });
}

async function waitForServer(endpoint, seconds) {
  for (let i = 0; i < seconds; i++) {
    const s = await probeServer(endpoint);
    if (s.up) return s;
    await new Promise(r => setTimeout(r, 1000));
  }
  return { up: false, error: `no answer within ${seconds}s` };
}

// Minimal process runner (extension.js has a richer one; importing it here
// would be circular).
function run(cmd, args) {
  return new Promise(resolve => {
    let child;
    try { child = cp.spawn(cmd, args, { windowsHide: true }); }
    catch (e) { resolve({ ok: false, out: String(e.message || e) }); return; }
    let out = '';
    child.on('error', e => resolve({ ok: false, out: String(e.message || e) }));
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { out += d; });
    child.on('close', code => resolve({ ok: code === 0, out: out.trim() }));
  });
}

// Stop the Ollama server processes. This affects every consumer on the machine
// (all VS Code windows, terminals) - that is the point of "bring it down". On
// Windows the tray app ('ollama app.exe') resurrects the server, so it is
// stopped too, mirroring the setup script's restart logic.
async function stopServer(log) {
  const results = [];
  if (process.platform === 'win32') {
    for (const image of ['ollama.exe', 'ollama app.exe']) {
      const r = await run('taskkill', ['/IM', image, '/F', '/T']);
      // Classify by output, not exit code: /T races the process tree (a child
      // such as the model runner can exit mid-kill) and then taskkill reports
      // failure even though the kill landed.
      let verdict;
      if (/SUCCESS/i.test(r.out)) verdict = 'stopped';
      else if (/not found/i.test(r.out)) verdict = 'not running';
      else verdict = `failed (${r.out.split('\n')[0] || 'unknown'})`;
      results.push(`${image}: ${verdict}`);
    }
  } else {
    const r = await run('pkill', ['-x', 'ollama']);
    results.push(`ollama: ${r.ok ? 'stopped' : 'not running'}`);
    if (process.platform === 'darwin') {
      const app = await run('pkill', ['-x', 'Ollama']);
      results.push(`Ollama.app: ${app.ok ? 'stopped' : 'not running'}`);
    }
  }
  log(`[model] stop server - ${results.join('; ')}`);
  return results;
}

// One instructions block used by every "something is missing" path, so the fix
// is always spelled out next to the error.
function instructions(cfg) {
  return [
    'How to get the model running:',
    `  1. Server down?  Run the command "Local Code AI: Start Model", or 'ollama serve' in any terminal.`,
    `     The server is a shared external process - one instance serves every VS Code window.`,
    `  2. Model '${cfg.model}' missing?  Re-run the setup script from its folder:`,
    '       pwsh -ExecutionPolicy Bypass -File .\\local.code.ai.ps1',
    `     It installs Ollama when needed and (re)creates the '${cfg.model}' alias.`,
    `  3. Custom server?  Check the 'localCodeAI.endpoint' and 'localCodeAI.model' settings`,
    `     (current: ${cfg.endpoint}, '${cfg.model}').`,
    `  4. Free memory later with "Local Code AI: Stop Model" - unload the model or stop the server.`
  ].join('\n');
}

module.exports = {
  probeServer, probeModel, loadedModels, showModel, loadModel, unloadModel,
  findOllama, spawnServer, waitForServer, stopServer, instructions, localHostPort
};
