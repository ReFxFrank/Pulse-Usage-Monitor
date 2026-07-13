#!/usr/bin/env node
/*
 * Build a single-file Pulse executable using Node's Single Executable
 * Application (SEA) support.
 *
 *   node build/make-exe.mjs            → dist-exe/pulse.exe (win) / pulse-linux / pulse-macos
 *
 * How it works:
 *   1. server.js is already a single zero-dependency CommonJS file — SEA can
 *      take it as-is, no bundler.
 *   2. The built frontend (web/dist/**) is embedded as SEA assets keyed
 *      "web/dist/<relpath>"; server.js reads them via node:sea at runtime.
 *   3. The blob is injected into a copy of THIS build machine's node binary
 *      (so run this script on the OS you're targeting — the release workflow
 *      runs it on a Windows runner for pulse.exe).
 *
 * Requires Node >= 20 (SEA assets). Uses npx postject for injection.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const buildDir = path.join(root, 'build');
const outDir = path.join(root, 'dist-exe');
const webDist = path.join(root, 'web', 'dist');

function log(msg) { console.log('[make-exe] ' + msg); }
function die(msg) { console.error('[make-exe] ERROR: ' + msg); process.exit(1); }

// 0. sanity
const major = parseInt(process.versions.node.split('.')[0], 10);
if (major < 20) die(`Node >= 20 required for SEA assets (running ${process.version})`);
if (!fs.existsSync(path.join(webDist, 'index.html'))) {
  die('web/dist not built. Run `npm run build` first.');
}

// 1. collect frontend assets
const assets = {};
(function walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(full);
    else {
      // keys use forward slashes on every platform
      const rel = path.relative(root, full).split(path.sep).join('/');
      assets[rel] = full;
    }
  }
})(webDist);
log(`embedding ${Object.keys(assets).length} frontend asset(s)`);

// 2. sea-config + blob
const seaConfig = {
  main: path.join(root, 'server.js'),
  output: path.join(buildDir, 'sea-prep.blob'),
  disableExperimentalSEAWarning: true,
  useCodeCache: false, // keep the blob portable and deterministic
  assets,
};
const cfgPath = path.join(buildDir, 'sea-config.json');
fs.mkdirSync(buildDir, { recursive: true });
fs.writeFileSync(cfgPath, JSON.stringify(seaConfig, null, 2));
log('generating SEA blob…');
execFileSync(process.execPath, ['--experimental-sea-config', cfgPath], { stdio: 'inherit' });

// 3. copy this platform's node binary and inject
const plat = process.platform;
const outName = plat === 'win32' ? 'pulse.exe' : plat === 'darwin' ? 'pulse-macos' : 'pulse-linux';
const outPath = path.join(outDir, outName);
fs.mkdirSync(outDir, { recursive: true });
fs.copyFileSync(process.execPath, outPath);
fs.chmodSync(outPath, 0o755);

log('injecting blob with postject…');
const postjectArgs = [
  'postject', outPath, 'NODE_SEA_BLOB', seaConfig.output,
  '--sentinel-fuse', 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2',
];
if (plat === 'darwin') postjectArgs.push('--macho-segment-name', 'NODE_SEA');
execFileSync(plat === 'win32' ? 'npx.cmd' : 'npx', ['--yes', ...postjectArgs], {
  stdio: 'inherit',
  shell: plat === 'win32',
});

const mb = (fs.statSync(outPath).size / 1024 / 1024).toFixed(1);
log(`done → ${path.relative(root, outPath)} (${mb} MB)`);
log('smoke test:  ' + outPath + ' --help');
