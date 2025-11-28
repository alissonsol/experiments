#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

function exitWith(msg, code = 1) {
  console.error(msg);
  process.exit(code);
}

const root = path.resolve(__dirname, '..');
const dist = path.join(root, 'dist');

if (!fs.existsSync(dist)) {
  exitWith('Error: `dist` directory not found. Run `npm run build` first.');
}

// Try to read manifest from dist first (copied by webpack), fallback to project manifest
let manifest = {};
const manifestDist = path.join(dist, 'manifest.json');
const manifestRoot = path.join(root, 'manifest.json');
try {
  const raw = fs.readFileSync(fs.existsSync(manifestDist) ? manifestDist : manifestRoot, 'utf8');
  manifest = JSON.parse(raw);
} catch (err) {
  // ignore, we'll fallback to package.json
}

const pkg = require(path.join(root, 'package.json')) || {};
const rawName = (manifest.name && typeof manifest.name === 'string') ? manifest.name : (pkg.name || 'extension');
const name = rawName.replace(/\s+/g, '-').replace(/[^a-zA-Z0-9\-_.]/g, '').toLowerCase();
const version = manifest.version || pkg.version || '0.0.0';

const packagesDir = path.join(root, 'packages');
if (!fs.existsSync(packagesDir)) fs.mkdirSync(packagesDir, { recursive: true });
const outName = `${name}-${version}.zip`;
const outPath = path.join(packagesDir, outName);

console.log(`Packaging extension -> ${outPath}`);

if (process.platform === 'win32') {
  // Use PowerShell Compress-Archive
  const psCmd = `Compress-Archive -Path \"${dist}\\*\" -DestinationPath \"${outPath}\" -Force`;
  const res = cp.spawnSync('powershell.exe', ['-NoProfile', '-Command', psCmd], { stdio: 'inherit' });
  if (res.status !== 0) exitWith('PowerShell compression failed.');
} else {
  // Try to use system zip (common on linux/mac)
  try {
    cp.execSync(`zip -r "${outPath}" .`, { cwd: dist, stdio: 'inherit' });
  } catch (err) {
    exitWith('`zip` command failed or is not installed. Install `zip` or use a node-based zipper.');
  }
}

if (fs.existsSync(outPath)) {
  console.log('Package created:', outPath);
  console.log('Distributable contents:');
  const files = fs.readdirSync(dist);
  files.forEach(f => console.log(' -', f));
} else {
  exitWith('Packaging failed: output file not found.');
}

process.exit(0);
