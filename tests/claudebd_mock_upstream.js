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
let sequenceId = null;
let sequenceIndex = 0;

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

function record(token, url, selection) {
  if (!logFile) return;
  const suffix = selection
    ? ` plan=${selection.id} step=${selection.index} fault=${selection.rule.fault || 'custom'}${selection.rule.resetAt ? ` reset_at=${selection.rule.resetAt}` : ''}`
    : '';
  try { fs.appendFileSync(logFile, `${token} ${url}${suffix}\n`); } catch {}
}

function selectRule(plan) {
  if (!Array.isArray(plan.sequence)) return null;
  const id = String(plan.id || 'default');
  if (id !== sequenceId) {
    sequenceId = id;
    sequenceIndex = 0;
  }
  const index = sequenceIndex++;
  return { id, index, rule: plan.sequence[index] || plan.default || { fault: 'ok' } };
}

function materializeRule(raw, token) {
  const rule = { ...raw };
  if (rule.fault === 'ok') return { ...rule, status: 200, body: { ok: true, account: token } };
  if (rule.fault === 'bare429') return { ...rule, status: 429, body: { error: 'overloaded' } };
  if (rule.fault === 'unified429') {
    rule.resetAt = Math.floor(Date.now() / 1000) + Number(rule.resetAfter || 2);
    return {
      ...rule,
      status: 429,
      headers: {
        'anthropic-ratelimit-unified-status': 'rejected',
        'anthropic-ratelimit-unified-reset': String(rule.resetAt)
      },
      body: {}
    };
  }
  if (rule.fault === 'auth401') return { ...rule, status: 401, body: { error: 'unauthorized' } };
  if (rule.fault === 'abort') {
    return { ...rule, status: 200, sse: ['data: chaos-first\n\n', 'data: chaos-never\n\n'], abortAfter: 1, delayMs: 15 };
  }
  return rule;
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
    const plan = readPlan();
    const selection = selectRule(plan);
    const rule = materializeRule(selection?.rule || (plan.byToken && plan.byToken[token]) || plan.default || { status: 200, body: '{}' }, token);
    if (selection) selection.rule = rule;
    record(token, req.url, selection);
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
