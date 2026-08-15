#!/usr/bin/env node
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const configPath = process.argv[2];
if (!configPath || !fs.existsSync(configPath)) {
  console.error('config not found');
  process.exit(3);
}

const candidates = [
  process.env.EDGE,
  process.env.CHROME,
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  process.env.LOCALAPPDATA ? `${process.env.LOCALAPPDATA}\\Google\\Chrome\\Application\\chrome.exe` : '',
].filter(Boolean);

const browserPath = candidates.find((p) => fs.existsSync(p));
if (!browserPath) {
  console.error('browser not found');
  process.exit(4);
}

const port = 9200 + Math.floor(Math.random() * 800);
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-widget-auth-'));

const browser = spawn(browserPath, [
  `--remote-debugging-port=${port}`,
  '--remote-allow-origins=*',
  `--user-data-dir=${profileDir}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-background-networking',
  'https://platform.deepseek.com/usage',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const getTargets = async () => {
  const res = await fetch(`http://127.0.0.1:${port}/json`);
  if (!res.ok) return [];
  return res.json();
};

let ws;
for (let i = 0; i < 60; i++) {
  try {
    const targets = await getTargets();
    const page = targets.find((t) => t.type === 'page' && /platform\.deepseek\.com/.test(t.url || ''));
    if (page) {
      ws = new WebSocket(page.webSocketDebuggerUrl);
      break;
    }
  } catch {}
  if (browser.exitCode !== null) break;
  await sleep(500);
}

if (!ws) {
  console.error('browser attach failed');
  try { browser.kill(); } catch {}
  process.exit(5);
}

const PATCH_JS = `(() => {
  if (window.__dsWidgetTokenHook) return;
  window.__dsWidgetTokenHook = true;
  const send = (value) => {
    try {
      const match = /Bearer\\s+(\\S+)/i.exec(String(value || ''));
      if (match && match[1]) document.title = 'DS_WIDGET_TOKEN:' + match[1];
    } catch (_) {}
  };
  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function(input, init) {
      try {
        const headers = (init && init.headers) || (input && input.headers);
        if (headers instanceof Headers) send(headers.get('authorization'));
        else if (Array.isArray(headers)) headers.forEach((row) => String(row[0]).toLowerCase() === 'authorization' && send(row[1]));
        else if (headers && typeof headers === 'object') Object.keys(headers).forEach((key) => key.toLowerCase() === 'authorization' && send(headers[key]));
      } catch (_) {}
      return originalFetch.apply(this, arguments);
    };
  }
  const originalSet = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    if (String(name || '').toLowerCase() === 'authorization') send(value);
    return originalSet.apply(this, arguments);
  };
})();`;

const TITLE_POLL_JS = `(() => {
  const t = document.title || '';
  return t.indexOf('DS_WIDGET_TOKEN:') === 0 ? t.slice('DS_WIDGET_TOKEN:'.length) : '';
})()`;

let seq = 0;
let saved = false;
const pollIds = new Set();

const send = (method, params = {}) => {
  if (ws.readyState !== 1) return;
  ws.send(JSON.stringify({ id: ++seq, method, params }));
};

const inject = () => {
  send('Runtime.evaluate', { expression: PATCH_JS, returnByValue: true });
};

const pollTitle = () => {
  if (ws.readyState !== 1) return;
  const id = ++seq;
  pollIds.add(id);
  ws.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression: TITLE_POLL_JS, returnByValue: true } }));
};

const saveToken = (token) => {
  if (saved) return;
  saved = true;
  try {
    const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    cfg.usageToken = token;
    fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), 'utf8');
    console.log('usage token saved');
  } catch (e) {
    console.error('save failed: ' + e.message);
    process.exitCode = 6;
  }
  try { send('Browser.close'); } catch {}
  setTimeout(() => process.exit(0), 800);
};

const maybeCapture = (headers) => {
  const m = /^Bearer\s+(\S+)$/i.exec(String((headers && (headers.Authorization || headers.authorization)) || ''));
  if (m && m[1].length > 20) saveToken(m[1]);
};

ws.addEventListener('open', () => {
  send('Network.enable');
  send('Page.enable');
  send('Runtime.enable');
  inject();
  pollTitle();
});

ws.addEventListener('message', (event) => {
  let msg;
  try { msg = JSON.parse(event.data); } catch { return; }
  if (pollIds.has(msg.id)) {
    pollIds.delete(msg.id);
    const value = msg.result && msg.result.result && msg.result.result.value;
    if (typeof value === 'string' && value) saveToken(value);
    return;
  }
  if (msg.method === 'Network.requestWillBeSent') {
    maybeCapture(msg.params && msg.params.request && msg.params.request.headers);
  } else if (msg.method === 'Page.frameNavigated' || msg.method === 'Runtime.executionContextCreated') {
    setTimeout(inject, 300);
  }
});

setInterval(() => {
  inject();
  pollTitle();
}, 2000);

browser.on('exit', () => {
  if (!saved) {
    console.error('browser closed before token captured');
    process.exit(7);
  }
});

setTimeout(() => {
  if (!saved) {
    console.error('timeout');
    try { browser.kill(); } catch {}
    process.exit(8);
  }
}, 5 * 60 * 1000);
