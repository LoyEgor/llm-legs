#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const fixture = process.env.CLAUDEB_DIR;
assert.ok(fixture, 'CLAUDEB_DIR is required');

const source = fs.readFileSync(path.join(root, 'bin', 'claudebd'), 'utf8');
const marker = '// Read the seed before scanAccounts: its initial pick rewrites the state file.';
const boundary = source.indexOf(marker);
assert.ok(boundary > 0, 'safe bootstrap boundary not found');

const exportsSource = `
globalThis.testApi = {
  states,
  pinnedAt,
  markRejected,
  eligibleForScope,
  noAccountsBody,
  persist,
  scanAccounts,
  disabledEvicts,
  setCurrent(value) { current = value; },
  getCurrent() { return current; }
};`;
const context = vm.createContext({
  require,
  process,
  console,
  Buffer,
  URL,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval
});
new vm.Script(source.slice(0, boundary) + exportsSource, { filename: 'bin/claudebd' }).runInContext(context);
const api = context.testApi;
const limitsDir = path.join(fixture, 'limits');
const tokensDir = path.join(fixture, 'tokens');
fs.mkdirSync(limitsDir, { recursive: true });
fs.mkdirSync(tokensDir, { recursive: true });

let assertions = 0;
function check(actual, expected, message) {
  assert.deepEqual(actual, expected, message);
  assertions += 1;
}
function ok(value, message) {
  assert.ok(value, message);
  assertions += 1;
}
function state(overrides = {}) {
  return {
    h5: 0,
    wk: 0,
    hreset: 0,
    wreset: 0,
    forcedUntil: 0,
    scopedWalls: {},
    authFailedUntil: 0,
    lastBareReject: 0,
    hAt: 0,
    wAt: 0,
    tokenMtime: 0,
    ...overrides
  };
}
function add(name, value = state()) {
  fs.writeFileSync(path.join(tokensDir, name), 'fixture\n', { mode: 0o600 });
  api.states.set(name, value);
}

const now = Math.floor(Date.now() / 1000);
add('header', state());
const headerUntil = now + 4800;
api.markRejected('header', { 'anthropic-ratelimit-unified-reset': String(headerUntil) }, 'fable');
check(api.states.get('header').scopedWalls.fable, headerUntil, 'header wall expiry');

const quotaUntil = now + 86400;
add('quota', state({
  fable: { used_percentage: 99, resets_at: quotaUntil, as_of: now, origin: 'usage' },
  auth: { status: 'ok' }
}));
api.markRejected('quota', {}, 'fable');
check(api.states.get('quota').scopedWalls.fable, quotaUntil, 'trusted quota wall expiry');

const weeklyUntil = now + 500000;
add('transient', state({
  wreset: weeklyUntil,
  fable: { used_percentage: 98, resets_at: weeklyUntil, as_of: now, origin: 'usage' },
  auth: { status: 'ok' }
}));
api.markRejected('transient', {}, 'fable');
let transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + 299 && transientUntil <= now + 301, 'first bare rejection uses 300 seconds');
ok(transientUntil !== weeklyUntil, 'bare rejection never uses weekly reset');
api.markRejected('transient', {}, 'fable');
transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + 899 && transientUntil <= now + 901, 'repeat bare rejection uses 900 seconds');
ok(transientUntil !== weeklyUntil, 'repeat bare rejection never uses weekly reset');

add('stale', state({
  fable: { used_percentage: 100, resets_at: weeklyUntil, as_of: now - 21601, origin: 'usage' },
  auth: { status: 'ok' }
}));
api.markRejected('stale', {}, 'fable');
ok(api.states.get('stale').scopedWalls.fable <= now + 301, 'stale snapshot is transient');
add('cached', state({
  fable: { used_percentage: 100, resets_at: weeklyUntil, as_of: now, origin: 'cached' },
  auth: { status: 'ok' }
}));
api.markRejected('cached', {}, 'fable');
ok(api.states.get('cached').scopedWalls.fable <= now + 301, 'cached snapshot is transient');
add('nonok', state({
  fable: { used_percentage: 100, resets_at: weeklyUntil, as_of: now, origin: 'usage' },
  auth: { status: 'error' }
}));
api.markRejected('nonok', {}, 'fable');
check(api.states.get('nonok').scopedWalls.fable, weeklyUntil, 'non-ok non-expired auth is currently trusted');

api.scanAccounts();
add('authfail', state({ authFailedUntil: now + 1000 }));
add('activewall', state({ scopedWalls: { fable: now + 1000 } }));
add('trustedfull', state({
  fable: { used_percentage: 100, resets_at: now + 1000, as_of: now, origin: 'usage' },
  auth: { status: 'ok' }
}));
api.scanAccounts();
api.states.get('stale').scopedWalls.fable = 0;
api.states.get('cached').scopedWalls.fable = 0;
check(api.eligibleForScope('authfail', 'fable'), false, 'failed auth excluded');
check(api.eligibleForScope('activewall', 'fable'), false, 'active scope wall excluded');
check(api.eligibleForScope('trustedfull', 'fable'), false, 'trusted full snapshot excluded');
check(api.eligibleForScope('stale', 'fable'), true, 'stale snapshot does not exclude after transient wall cleared');
check(api.eligibleForScope('cached', 'fable'), true, 'cached snapshot does not exclude after transient wall cleared');

const disabledFile = path.join(fixture, 'disabled');
fs.writeFileSync(disabledFile, 'pinned\ndisabled\nstateonly\n');
const disabledTime = new Date(Date.now() - 2000);
fs.utimesSync(disabledFile, disabledTime, disabledTime);
add('pinned');
add('disabled');
add('stateonly');
api.setCurrent('pinned');
api.pinnedAt.set('pinned', Date.now());
api.scanAccounts();
check(api.disabledEvicts('disabled'), true, 'disabled account without pin is evicted');
check(api.disabledEvicts('pinned'), false, 'newer manual pin prevents disabled eviction');
check(api.getCurrent(), 'pinned', 'newer manual pin overrides disabled membership');
check(api.eligibleForScope('pinned', 'fable'), true, 'pinned disabled account stays eligible');
check(api.eligibleForScope('disabled', 'fable'), false, 'disabled account excluded');
const stateFile = path.join(fixture, '.claudeb-state');
fs.writeFileSync(stateFile, 'stateonly\n');
const stateTime = new Date(Date.now() + 1000);
fs.utimesSync(stateFile, stateTime, stateTime);
api.setCurrent('stateonly');
api.scanAccounts();
check(api.getCurrent() === 'stateonly', false, 'state-file mtime alone does not restore a pin');

add('wall-a', state({ scopedWalls: { fable: now + 700 } }));
add('wall-b', state({ scopedWalls: { fable: now + 400 } }));
fs.writeFileSync(disabledFile, 'header\nquota\ntransient\nstale\ncached\nnonok\nauthfail\nactivewall\ntrustedfull\npinned\ndisabled\nstateonly\n');
api.scanAccounts();
check(api.noAccountsBody('fable').retry_at, now + 400, '503 body uses earliest wall expiry');

const learnedFile = path.join(limitsDir, 'learned.json');
fs.writeFileSync(learnedFile, JSON.stringify({ fable: { used_percentage: 12 } }));
api.persist('learned', {
  five_hour: { used_percentage: 25, resets_at: now + 2000 },
  seven_day: { used_percentage: 50, resets_at: now + 3000 }
});
const learned = JSON.parse(fs.readFileSync(learnedFile, 'utf8'));
check(learned.five_hour.origin, 'headers', 'five-hour origin stamped');
check(learned.seven_day.origin, 'headers', 'weekly origin stamped');
ok(Number.isInteger(learned.five_hour.as_of), 'five-hour as_of stamped');
ok(Number.isInteger(learned.seven_day.as_of), 'weekly as_of stamped');
check(learned.fable.used_percentage, 12, 'unrelated snapshot bucket preserved');

const logs = fs.readFileSync(path.join(fixture, 'claudebd.log'), 'utf8').trim().split('\n');
const wallLines = logs.filter((line) => line.includes(' wall account='));
ok(wallLines.some((line) => / wall account=header scope=fable until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z reason=header$/.test(line)), 'header wall log format');
ok(wallLines.some((line) => / wall account=quota scope=fable until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z reason=quota$/.test(line)), 'quota wall log format');
ok(wallLines.some((line) => / wall account=transient scope=fable until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z reason=transient$/.test(line)), 'transient wall log format');

process.stdout.write(`PASS: claudebd decision logic (${assertions} assertions)\n`);
