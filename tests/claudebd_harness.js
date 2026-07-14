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
  markAuthFailure,
  eligibleForScope,
  noAccountsBody,
  persist,
  scanAccounts,
  disabledEvicts,
  statusPayload,
  daemonStateFile,
  persistDaemonState,
  setCurrent(value) { current = value; },
  getCurrent() { return current; }
};`;
function boot() {
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
  return context.testApi;
}
const api = boot();
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
    scopedWallReason: {},
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
api.markRejected('header', {
  'anthropic-ratelimit-unified-status': 'rejected',
  'anthropic-ratelimit-unified-reset': String(headerUntil)
}, 'fable');
check(api.states.get('header').scopedWalls.fable, headerUntil, 'header wall expiry');
check(api.states.get('header').scopedWallReason.fable, 'header', 'unified fable rejection keeps its scoped reason');
check(api.states.get('header').forcedUntil, 0, 'unified fable rejection does not wall general');

const quotaUntil = now + 86400;
add('quota', state({
  fable: { used_percentage: 99, resets_at: quotaUntil, as_of: now, origin: 'usage' },
  auth: { status: 'ok' }
}));
api.markRejected('quota', {}, 'fable');
check(api.states.get('quota').scopedWalls.fable, quotaUntil, 'trusted quota wall expiry');
check(api.states.get('quota').forcedUntil, 0, 'fable quota rejection does not wall general');

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
check(api.states.get('transient').forcedUntil, 0, 'fable transient rejection does not wall general');

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
const nonokUntil = api.states.get('nonok').scopedWalls.fable;
ok(nonokUntil !== weeklyUntil, 'non-ok auth status is no longer trusted for a quota wall');
ok(nonokUntil <= now + 301, 'non-ok auth falls back to a transient wall');

add('legacynoauth', state({
  fable: { used_percentage: 100, resets_at: weeklyUntil, as_of: now, origin: 'usage' }
}));
api.markRejected('legacynoauth', {}, 'fable');
check(api.states.get('legacynoauth').scopedWalls.fable, weeklyUntil, 'a snapshot with no auth field at all (legacy) is still trusted');

api.scanAccounts();
check(api.eligibleForScope('header', 'general'), true, 'unified fable rejection preserves general eligibility');
check(api.eligibleForScope('header', 'fable'), false, 'unified fable rejection blocks fable eligibility');
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

// Menu disable is authoritative over an OLDER manual pin: it evicts the account
// and purges the pin from memory + daemon-state.json (no restart resurrection).
add('menupinned');
fs.writeFileSync(disabledFile, 'pinned\ndisabled\nstateonly\nmenupinned\n');
const menuDisableAt = new Date();
fs.utimesSync(disabledFile, menuDisableAt, menuDisableAt);
api.pinnedAt.set('menupinned', Date.now() - 5000);
api.setCurrent('menupinned');
api.scanAccounts();
check(api.disabledEvicts('menupinned'), true, 'disable newer than the pin evicts the pinned account');
check(api.pinnedAt.has('menupinned'), false, 'evicted pin dropped from memory');
const dsAfterDisable = JSON.parse(fs.readFileSync(api.daemonStateFile, 'utf8'));
check(dsAfterDisable.pinnedAt['menupinned'], undefined, 'evicted pin purged from daemon-state.json');
ok(api.getCurrent() !== 'menupinned', 'disabled pinned account is no longer current');

add('wall-a', state({ scopedWalls: { fable: now + 700 } }));
add('wall-b', state({ scopedWalls: { fable: now + 400 } }));
add('wall-disabled', state({ forcedUntil: now + 100 }));
add('wall-authfail', state({ forcedUntil: now + 200, authFailedUntil: now + 1000 }));
fs.writeFileSync(disabledFile, 'header\nquota\ntransient\nstale\ncached\nnonok\nlegacynoauth\nauthfail\nactivewall\ntrustedfull\npinned\ndisabled\nstateonly\nmenupinned\nwall-disabled\n');
api.setCurrent(null);
api.scanAccounts();
check(api.noAccountsBody('fable').retry_at, now + 400, '503 body uses earliest wall expiry');
check(api.statusPayload().all_walled_until.general, null, 'fable-only walls leave general scope available');
check(api.statusPayload().all_walled_until.fable, now + 400, 'fable aggregate uses earliest eligible account wall');
api.states.get('wall-a').forcedUntil = now + 800;
api.states.get('wall-b').forcedUntil = now + 500;
check(api.statusPayload().all_walled_until.general, now + 500, 'general aggregate uses earliest eligible account wall');
check(api.statusPayload().all_walled_until.fable, now + 500, 'scope aggregate waits for every blocker on an account');

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

// --- daemon-state.json persistence across restarts ----------------------
const persistNow = Math.floor(Date.now() / 1000);
add('persist-fable', state());
api.markRejected('persist-fable', {
  'anthropic-ratelimit-unified-status': 'rejected',
  'anthropic-ratelimit-unified-reset': String(persistNow + 5000)
}, 'fable');
const persistFableUntil = api.states.get('persist-fable').scopedWalls.fable;

add('persist-general', state());
api.markRejected('persist-general', { 'anthropic-ratelimit-unified-status': 'rejected', 'anthropic-ratelimit-unified-reset': String(persistNow + 6000) }, 'general');
const persistGeneralUntil = api.states.get('persist-general').forcedUntil;

add('persist-authfail', state());
api.markAuthFailure('persist-authfail', 401);
const persistAuthUntil = api.states.get('persist-authfail').authFailedUntil;

add('persist-pin', state());
api.pinnedAt.set('persist-pin', Date.now());
api.persistDaemonState();

const dsFile = api.daemonStateFile;
const dsRaw = JSON.parse(fs.readFileSync(dsFile, 'utf8'));
check(dsRaw.accounts['persist-fable'].scopedWalls.fable, persistFableUntil, 'daemon-state.json persists fable wall expiry');
check(dsRaw.accounts['persist-fable'].scopedWallReason.fable, 'header', 'daemon-state.json persists fable wall reason');
check(dsRaw.accounts['persist-general'].forcedUntil, persistGeneralUntil, 'daemon-state.json persists general wall expiry');
check(dsRaw.accounts['persist-general'].forcedReason, 'header', 'daemon-state.json persists general wall reason');
check(dsRaw.accounts['persist-authfail'].authFailedUntil, persistAuthUntil, 'daemon-state.json persists auth failure');
ok(typeof dsRaw.pinnedAt['persist-pin'] === 'number', 'daemon-state.json persists manual pin');

const api2 = boot();
api2.scanAccounts();
check(api2.states.get('persist-fable').scopedWalls.fable, persistFableUntil, 'fable wall survives simulated restart');
check(api2.states.get('persist-general').forcedUntil, persistGeneralUntil, 'general wall survives simulated restart');
check(api2.states.get('persist-general').forcedReason, 'header', 'general wall reason survives simulated restart');
check(api2.states.get('persist-authfail').authFailedUntil, persistAuthUntil, 'auth failure survives simulated restart');
check(api2.pinnedAt.get('persist-pin'), dsRaw.pinnedAt['persist-pin'], 'manual pin survives simulated restart');

const changedTokenTime = new Date(Date.now() + 2000);
fs.utimesSync(path.join(tokensDir, 'persist-authfail'), changedTokenTime, changedTokenTime);
api2.scanAccounts();
const clearedOnDisk = JSON.parse(fs.readFileSync(dsFile, 'utf8'));
check(clearedOnDisk.accounts['persist-authfail']?.authFailedUntil, undefined, 'token change clears persisted auth failure');

fs.writeFileSync(dsFile, JSON.stringify({
  accounts: { 'persist-fable': { scopedWalls: { fable: persistNow - 100 }, scopedWallReason: { fable: 'header' } } },
  pinnedAt: {}
}));
const api3 = boot();
api3.scanAccounts();
check(api3.states.get('persist-fable').scopedWalls.fable, undefined, 'expired persisted wall pruned on load, not resurrected');

fs.writeFileSync(dsFile, '{not json');
const api4 = boot();
api4.scanAccounts();
check(api4.states.get('persist-fable').scopedWalls.fable, undefined, 'corrupt daemon-state.json starts clean (wall not resurrected)');
check(api4.states.get('persist-general').forcedUntil, 0, 'corrupt daemon-state.json does not resurrect general wall');
check(api4.states.get('persist-authfail').authFailedUntil, 0, 'corrupt daemon-state.json does not resurrect auth failure');
const corruptLines = fs.readFileSync(path.join(fixture, 'claudebd.log'), 'utf8').trim().split('\n')
  .filter((line) => line.includes('daemon-state corrupt'));
check(corruptLines.length, 1, 'exactly one daemon-state corrupt log line emitted');

const logs = fs.readFileSync(path.join(fixture, 'claudebd.log'), 'utf8').trim().split('\n');
const wallLines = logs.filter((line) => line.includes(' wall account='));
ok(wallLines.some((line) => / wall account=header scope=fable until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z reason=header$/.test(line)), 'header wall log format');
ok(wallLines.some((line) => / wall account=quota scope=fable until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z reason=quota$/.test(line)), 'quota wall log format');
ok(wallLines.some((line) => / wall account=transient scope=fable until=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000Z reason=transient$/.test(line)), 'transient wall log format');

process.stdout.write(`PASS: claudebd decision logic (${assertions} assertions)\n`);
