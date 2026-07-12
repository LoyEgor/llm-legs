#!/usr/bin/env node
'use strict';

// Scriptable stand-in for api.anthropic.com used by test_claudebd_live.sh.
// Behavior is driven entirely by MOCK_PLAN (a JSON file re-read on every
// request) so a scenario can change upstream responses between requests
// without restarting anything. The proxy signs each request with an account
// token, so the Authorization bearer value identifies the account here.

const http = require('node:http');
const fs = require('node:fs');

const planFile = process.env.MOCK_PLAN;
const portFile = process.env.MOCK_PORT_FILE;
const logFile = process.env.MOCK_LOG;

function readPlan() {
  try {
    return JSON.parse(fs.readFileSync(planFile, 'utf8'));
  } catch {
    return { byToken: {}, default: { status: 200, body: '{}' } };
  }
}

function tokenOf(req) {
  const auth = String(req.headers.authorization || '');
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : '';
}

function record(token, url) {
  if (!logFile) return;
  try { fs.appendFileSync(logFile, `${token} ${url}\n`); } catch {}
}

function respondSse(res, rule) {
  res.writeHead(rule.status || 200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    ...(rule.headers || {})
  });
  const chunks = rule.sse;
  let i = 0;
  const delay = typeof rule.delayMs === 'number' ? rule.delayMs : 15;
  const abortAfter = typeof rule.abortAfter === 'number' ? rule.abortAfter : -1;
  const tick = () => {
    if (res.destroyed) return;
    if (abortAfter >= 0 && i >= abortAfter) {
      // Simulate an upstream connection that dies mid-body: destroy the
      // socket without a clean end so the proxy sees a truncated stream.
      res.destroy();
      return;
    }
    if (i >= chunks.length) {
      res.end();
      return;
    }
    res.write(chunks[i]);
    i += 1;
    setTimeout(tick, delay);
  };
  tick();
}

const server = http.createServer((req, res) => {
  const token = tokenOf(req);
  // Drain the request body so keep-alive sockets stay clean.
  req.on('data', () => {});
  req.on('end', () => {
    record(token, req.url);
    const plan = readPlan();
    const rule = (plan.byToken && plan.byToken[token]) || plan.default || { status: 200, body: '{}' };
    if (Array.isArray(rule.sse)) return respondSse(res, rule);
    const body = typeof rule.body === 'string' ? rule.body : JSON.stringify(rule.body ?? {});
    const headers = { 'content-type': 'application/json', ...(rule.headers || {}) };
    res.writeHead(rule.status || 200, headers);
    res.end(body);
  });
  req.on('error', () => { if (!res.destroyed) res.destroy(); });
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  if (portFile) fs.writeFileSync(portFile, String(port));
  process.stdout.write(`mock listening ${port}\n`);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
