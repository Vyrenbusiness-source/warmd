// warmd status bar: shows when warmd works in this workspace. Plain JS, no build step, no dependencies.
// Cheap by design: the signals warmd leaves on disk are watched and stat'ed directly (fs.watch, 3 s fallback);
// `warmd state --json` is spawned only when one of them changed, never on every tick.
'use strict';
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const cp = require('child_process');

const WIN = process.platform === 'win32';
const POLL_MS = 3000, FLASH_MS = 10000, ACTIVE_RECHECK_MS = 30000, DEBOUNCE_MS = 300;

// /c/Users/x (Git Bash) and C:\Users\x both become C:/Users/x on Windows
function nativePath(p) {
  if (!p) return p;
  p = p.trim();
  if (!WIN) return p;
  const m = /^\/([a-zA-Z])(\/.*)?$/.exec(p);
  if (m) p = m[1].toUpperCase() + ':' + (m[2] || '/');
  return p.replace(/\\/g, '/');
}

function exists(p) { try { fs.accessSync(p); return true; } catch (_) { return false; } }
function isFile(p) { try { return fs.statSync(p).isFile(); } catch (_) { return false; } }

function findWarmd() {
  const cfg = vscode.workspace.getConfiguration('warmd').get('path');
  if (cfg) return nativePath(cfg);
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  dirs.push(path.join(os.homedir(), '.local', 'bin'), path.join(os.homedir(), '.warmd', 'bin'));
  for (const d of dirs) { const f = path.join(d, 'warmd'); if (isFile(f)) return f; }
  return '';
}

function findBash() {
  const cfg = vscode.workspace.getConfiguration('warmd').get('bash');
  if (cfg) return cfg;
  const pf = [process.env.ProgramFiles, process.env['ProgramW6432'], 'C:\\Program Files'].filter(Boolean);
  for (const p of pf) for (const rel of ['Git\\bin\\bash.exe', 'Git\\usr\\bin\\bash.exe']) {
    const f = path.join(p, rel); if (isFile(f)) return f;
  }
  // bash.exe on PATH, but not the WSL launcher in System32
  for (const d of (process.env.PATH || '').split(path.delimiter)) {
    const f = path.join(d, 'bash.exe');
    if (!/system32/i.test(d) && isFile(f)) return f;
  }
  return 'bash';
}

// The git common dir of a checkout: .git is a folder (main checkout) or a file "gitdir: <dir>" (worktree, with commondir)
function gitCommonDir(root) {
  for (let d = root, i = 0; i < 8; i++, d = path.dirname(d)) {
    const g = path.join(d, '.git');
    try {
      const s = fs.statSync(g);
      if (s.isDirectory()) return g;
      const m = /^gitdir:\s*(.+)$/m.exec(fs.readFileSync(g, 'utf8'));
      if (!m) return '';
      const gd = path.resolve(d, nativePath(m[1]));
      try { return path.resolve(gd, nativePath(fs.readFileSync(path.join(gd, 'commondir'), 'utf8'))); } catch (_) { return gd; }
    } catch (_) { /* go up */ }
    if (path.dirname(d) === d) break;
  }
  return '';
}

// The .warmd folder of the project: the workspace root, else a direct subfolder (a Unity project inside the repo)
function stateDir(root) {
  const own = path.join(root, '.warmd');
  if (exists(own)) return own;
  try {
    for (const e of fs.readdirSync(root, { withFileTypes: true })) {
      if (e.isDirectory() && exists(path.join(root, e.name, '.warmd'))) return path.join(root, e.name, '.warmd');
    }
  } catch (_) { /* none */ }
  return own;
}

function activate(ctx) {
  const folder = (vscode.workspace.workspaceFolders || [])[0];
  if (!folder || folder.uri.scheme !== 'file') return;
  const root = folder.uri.fsPath;
  const script = findWarmd();
  if (!exists(path.join(root, '.warmd')) && !exists(path.join(root, 'warmd.conf')) && !script) return;

  const bash = WIN ? findBash() : '';
  const out = vscode.window.createOutputChannel('warmd');
  const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  item.command = 'warmd.status';
  ctx.subscriptions.push(item, out);

  let st = null, lastLine = null, flashUntil = 0, flashTimer = null, sig = '', busy = false, again = false, lastSpawn = 0;
  const watchers = new Map();
  let common = gitCommonDir(root), sdir = stateDir(root);

  function run(args, opts, cb) {
    if (!script) { cb(new Error('warmd not found: set warmd.path'), '', ''); return; }
    const file = WIN ? bash : script, argv = WIN ? [script, ...args] : args;
    return cp.execFile(file, argv, Object.assign({ cwd: root, windowsHide: true, maxBuffer: 1 << 20 }, opts), cb);
  }

  function render() {
    if (!script && !st) { item.text = '$(zap) warmd'; item.tooltip = 'warmd: not found on PATH (setting warmd.path)'; item.color = new vscode.ThemeColor('disabledForeground'); item.show(); return; }
    const s = st || { active: false, what: 'idle', agents: 0, last: '', line: '' };
    let text, dim = false;
    if (Date.now() < flashUntil && s.last) text = s.last === 'green' ? '$(pass) warmd' : '$(error) warmd';
    else if (s.what === 'ci-wait') text = '$(cloud) CI';
    else if (s.active && s.what === 'batch') text = `$(organization) warmd ${s.agents} agent${s.agents === 1 ? '' : 's'}`;
    else if (s.active) text = `$(sync~spin) warmd ${s.what}`;
    else { text = '$(zap) warmd'; dim = true; }
    item.text = text;
    item.color = dim ? new vscode.ThemeColor('disabledForeground') : undefined;
    let head;
    if (s.active) {
      head = `warmd: ${s.what}` + (s.agents ? `, ${s.agents} agents in the batch` : '');
      if (s.since) head += `, since ${new Date(s.since * 1000).toLocaleTimeString()}`;
    } else head = 'warmd: idle';
    item.tooltip = head + '\n' + (s.line ? `last: ${s.line}` : 'no run yet') + '\nclick: warmd status';
    item.show();
  }

  function refresh() {
    if (busy) { again = true; return; }
    busy = true; lastSpawn = Date.now();
    run(['state', '--json'], { timeout: 30000 }, (err, stdout) => {
      busy = false;
      const line = String(stdout || '').split(/\r?\n/).find(l => l.startsWith('{'));
      if (line) {
        try {
          const n = JSON.parse(line);
          // A new last result flashes $(pass) or $(error) for 10 s; the first read after start does not
          if (lastLine !== null && n.line && n.line !== lastLine) {
            flashUntil = Date.now() + FLASH_MS;
            clearTimeout(flashTimer); flashTimer = setTimeout(render, FLASH_MS + 50);
          }
          lastLine = n.line || '';
          st = n;
        } catch (_) { /* keep the old state */ }
      } else if (err) out.appendLine(`warmd state failed: ${err.message}`);
      render();
      if (again) { again = false; refresh(); }
    });
  }

  // What is watched and stat'ed: run marks, merge lock, CI wait, run log, batch marker and its done list
  function files() {
    const r = path.join(sdir, 'run');
    const l = [path.join(r, 'active'), path.join(r, 'runs.log'), path.join(sdir, 'merge.owner'), path.join(sdir, 'ci.wait'), path.join(root, '.warmd', 'ci.wait')];
    if (common) l.push(path.join(common, 'warmd-batch'), path.join(common, 'warmd-batch-done'), path.join(common, 'warmd-batch-alive'));
    return l;
  }
  function signature() {
    let s = '';
    for (const f of files()) {
      try {
        const t = fs.statSync(f);
        s += `${f}:${t.mtimeMs}:${t.size}`;
        if (t.isDirectory()) s += ':' + fs.readdirSync(f).join(',');
        s += '|';
      } catch (_) { s += '-|'; }
    }
    return s;
  }
  function tick() {
    const n = signature();
    const stale = st && st.active && Date.now() - lastSpawn > ACTIVE_RECHECK_MS;   // a run that died without cleanup
    if (n !== sig || stale) { sig = n; refresh(); }
    watchAll();
  }
  let deb = null;
  function poke() { clearTimeout(deb); deb = setTimeout(tick, DEBOUNCE_MS); }
  function watch(dir) {
    if (watchers.has(dir) || !exists(dir)) return;
    try {
      const w = fs.watch(dir, { persistent: false }, poke);
      w.on('error', () => { try { w.close(); } catch (_) { } watchers.delete(dir); });
      watchers.set(dir, w);
    } catch (_) { /* polling covers it */ }
  }
  function watchAll() {
    if (!common) common = gitCommonDir(root);
    if (!exists(sdir)) sdir = stateDir(root);
    watch(sdir); watch(path.join(sdir, 'run')); watch(path.join(sdir, 'run', 'active')); watch(path.join(root, '.warmd'));
    if (common) watch(common);
  }

  ctx.subscriptions.push(vscode.commands.registerCommand('warmd.status', () => {
    out.show(true);
    out.appendLine(`$ warmd status   (${root})`);
    const c = run(['status'], { timeout: 120000 }, (err) => { if (err) out.appendLine(`(exit ${err.code})`); out.appendLine(''); });
    if (c) { c.stdout.on('data', d => out.append(String(d))); c.stderr.on('data', d => out.append(String(d))); }
    else out.appendLine('warmd not found: set warmd.path');
  }));
  ctx.subscriptions.push(vscode.commands.registerCommand('warmd.refresh', () => { sig = ''; tick(); }));

  render();
  watchAll();
  sig = signature();
  refresh();
  const iv = setInterval(tick, POLL_MS);
  ctx.subscriptions.push({ dispose() { clearInterval(iv); clearTimeout(deb); clearTimeout(flashTimer); for (const w of watchers.values()) { try { w.close(); } catch (_) { } } } });
}

function deactivate() { }

module.exports = { activate, deactivate, nativePath };
