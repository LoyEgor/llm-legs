#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const fixture = process.env.CLAUDEB_DIR;
assert.ok(fixture, 'CLAUDEB_DIR is required');
const mainLimitsFile = process.env.LLM_LIMITS_FILE;
assert.ok(mainLimitsFile, 'LLM_LIMITS_FILE is required');

const source = fs.readFileSync(path.join(root, 'bin', 'claudebd'), 'utf8');
const marker = '// Read the seeds before scanAccounts: its initial picks rewrite the state files.';
const boundary = source.indexOf(marker);
assert.ok(boundary > 0, 'safe bootstrap boundary not found');

const exportsSource = `
globalThis.testApi = {
  states,
  pinnedAt,
  markRejected,
  markAuthFailure,
  updateFromHeaders,
  markPlanIncapable,
  eligibleForScope,
  noAccountsBody,
  persist,
  scanAccounts,
  disabledEvicts,
  statusPayload,
  daemonStateFile,
  persistDaemonState,
  capacityWallDurationsS,
  capacityWallRepeatWindowS,
  switchForScope,
  selectAccountForScope,
  claimedUntil,
  setCurrent(value) { current = value; },
  getCurrent() { return current; },
  getFableCurrent() { return currentByScope.fable; },
  getDaemonState() { return daemonState; }
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
process.env.CLAUDEBD_CAPACITY_WALL_FIRST_MS = '1000';
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
    capacityEscalation: {},
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
const [tier0S, tier1S, tier2S] = api.capacityWallDurationsS;
api.markRejected('transient', {}, 'fable');
let transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + tier0S - 1 && transientUntil <= now + tier0S + 1, 'first bare rejection uses the short first-tier wall');
ok(transientUntil !== weeklyUntil, 'bare rejection never uses weekly reset');
check(api.states.get('transient').capacityEscalation.fable.tier, 0, 'first bare rejection starts at tier 0');

api.markRejected('transient', {}, 'fable');
transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + tier1S - 1 && transientUntil <= now + tier1S + 1, 'repeat bare rejection within the window escalates to the next tier');
check(api.states.get('transient').capacityEscalation.fable.tier, 1, 'repeat bare rejection escalates to tier 1');

api.markRejected('transient', {}, 'fable');
transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + tier2S - 1 && transientUntil <= now + tier2S + 1, 'third bare rejection within the window escalates to the capped tier');
check(api.states.get('transient').capacityEscalation.fable.tier, 2, 'third bare rejection escalates to tier 2 (capped)');

api.markRejected('transient', {}, 'fable');
transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + tier2S - 1 && transientUntil <= now + tier2S + 1, 'further bare rejections stay capped at the last tier');
check(api.states.get('transient').capacityEscalation.fable.tier, 2, 'tier never exceeds the last configured tier');

// Simulate a quiet period by pushing the escalation state's expiry outside
// the repeat window: the next bare rejection must reset to the short tier.
api.states.get('transient').capacityEscalation.fable.until = now - api.capacityWallRepeatWindowS - 10;
api.markRejected('transient', {}, 'fable');
transientUntil = api.states.get('transient').scopedWalls.fable;
ok(transientUntil >= now + tier0S - 1 && transientUntil <= now + tier0S + 1, 'a quiet period resets escalation to the short first tier');
check(api.states.get('transient').capacityEscalation.fable.tier, 0, 'quiet period resets tier to 0');
check(api.states.get('transient').forcedUntil, 0, 'fable transient rejection does not wall general');

add('transient-general', state());
api.markRejected('transient-general', {}, 'general');
let generalUntil = api.states.get('transient-general').forcedUntil;
ok(generalUntil >= now + tier0S - 1 && generalUntil <= now + tier0S + 1, 'first bare general rejection uses the short first-tier wall');
check(api.states.get('transient-general').forcedReason, 'transient', 'bare general rejection reason is transient');
api.markRejected('transient-general', {}, 'general');
generalUntil = api.states.get('transient-general').forcedUntil;
ok(generalUntil >= now + tier1S - 1 && generalUntil <= now + tier1S + 1, 'repeat bare general rejection escalates to the next tier');

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
let projection = api.statusPayload().accounts;
check(projection.header.blocked.general, null, 'fable-scoped wall leaves general status unblocked');
check(projection.header.blocked.fable, 'wall', 'fable-scoped wall is projected as a fable blockage');
check(projection.header.usable.fable, false, 'fable-scoped wall marks only fable status unusable');
check(projection.disabled.usable.general, true, 'disabled under-limit account remains usable in status projection');
check(projection.disabled.blocked.general, null, 'disabled membership does not fabricate a rotation blockage');
add('at-limit', state({ h5: 100, wk: 100, hreset: now + 2000, wreset: now + 3000 }));
api.scanAccounts();
projection = api.statusPayload().accounts;
check(projection['at-limit'].blocked.general, 'limit-5h', 'five-hour limit is the first limit reason in status');
check(projection['at-limit'].usable.general, false, 'five-hour limited account is not generally usable');
fs.unlinkSync(path.join(tokensDir, 'at-limit'));
api.states.delete('at-limit');
api.scanAccounts();
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
fs.writeFileSync(disabledFile, 'header\nquota\ntransient\ntransient-general\nstale\ncached\nnonok\nlegacynoauth\nauthfail\nactivewall\ntrustedfull\npinned\ndisabled\nstateonly\nmenupinned\nwall-disabled\n');
api.setCurrent(null);
api.scanAccounts();
check(api.noAccountsBody('fable').retry_at, now + 400, '503 body uses earliest wall expiry');
check(api.statusPayload().all_walled_until.general, null, 'fable-only walls leave general scope available');
check(api.statusPayload().all_walled_until.fable, now + 400, 'fable aggregate uses earliest eligible account wall');
api.states.get('wall-a').forcedUntil = now + 800;
api.states.get('wall-b').forcedUntil = now + 500;
check(api.statusPayload().all_walled_until.general, now + 500, 'general aggregate uses earliest eligible account wall');
check(api.statusPayload().all_walled_until.fable, now + 500, 'scope aggregate waits for every blocker on an account');
const aggregateDisabled = fs.readFileSync(disabledFile, 'utf8');
add('auth-wall-a', state({ authFailedUntil: now + 900 }));
add('auth-wall-b', state({ authFailedUntil: now + 600 }));
fs.writeFileSync(disabledFile, fs.readdirSync(tokensDir).filter((name) => name !== 'auth-wall-a' && name !== 'auth-wall-b').join('\n') + '\n');
api.scanAccounts();
check(api.statusPayload().all_walled_until.general, now + 600, 'all auth-failed accounts report the earliest recovery time');
fs.writeFileSync(disabledFile, aggregateDisabled);
api.scanAccounts();

const learnedFile = path.join(limitsDir, 'learned.json');
fs.writeFileSync(learnedFile, JSON.stringify({ fable: { used_percentage: 12 } }));
api.persist('learned', {
  five_hour: { used_percentage: 25, resets_at: now + 2000 },
  seven_day: { used_percentage: 50, resets_at: now + 3000 }
});
const learned = JSON.parse(fs.readFileSync(learnedFile, 'utf8'));
check(learned.five_hour.origin, 'headers', 'five-hour origin stamped');
ok(!('seven_day' in learned), 'persist drops a weekly bucket instead of stamping it origin=headers');
ok(Number.isInteger(learned.five_hour.as_of), 'five-hour as_of stamped');
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

add('persist-capacity', state());
api.markRejected('persist-capacity', {}, 'fable');
const persistCapacityUntil = api.states.get('persist-capacity').scopedWalls.fable;
const persistCapacityTier = api.states.get('persist-capacity').capacityEscalation.fable.tier;

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
check(dsRaw.accounts['persist-capacity'].capacityEscalation.fable.tier, persistCapacityTier, 'daemon-state.json persists capacity escalation tier');
check(dsRaw.accounts['persist-capacity'].capacityEscalation.fable.until, persistCapacityUntil, 'daemon-state.json persists capacity escalation until');
ok(typeof dsRaw.pinnedAt['persist-pin'] === 'number', 'daemon-state.json persists manual pin');

const api2 = boot();
api2.scanAccounts();
check(api2.states.get('persist-fable').scopedWalls.fable, persistFableUntil, 'fable wall survives simulated restart');
check(api2.states.get('persist-general').forcedUntil, persistGeneralUntil, 'general wall survives simulated restart');
check(api2.states.get('persist-general').forcedReason, 'header', 'general wall reason survives simulated restart');
check(api2.states.get('persist-authfail').authFailedUntil, persistAuthUntil, 'auth failure survives simulated restart');
check(api2.states.get('persist-capacity').capacityEscalation.fable.tier, persistCapacityTier, 'capacity escalation tier survives simulated restart');
check(api2.states.get('persist-capacity').capacityEscalation.fable.until, persistCapacityUntil, 'capacity escalation until survives simulated restart');
check(api2.pinnedAt.get('persist-pin'), dsRaw.pinnedAt['persist-pin'], 'manual pin survives simulated restart');

const changedTokenTime = new Date(Date.now() + 2000);
fs.utimesSync(path.join(tokensDir, 'persist-authfail'), changedTokenTime, changedTokenTime);
api2.scanAccounts();
const clearedOnDisk = JSON.parse(fs.readFileSync(dsFile, 'utf8'));
check(clearedOnDisk.accounts['persist-authfail']?.authFailedUntil, undefined, 'token change clears persisted auth failure');

fs.writeFileSync(dsFile, JSON.stringify({
  accounts: {
    'persist-fable': { scopedWalls: { fable: persistNow - 100 }, scopedWallReason: { fable: 'header' } },
    'persist-capacity': { capacityEscalation: { fable: { tier: 2, until: persistNow - api.capacityWallRepeatWindowS - 100 } } }
  },
  pinnedAt: {}
}));
const api3 = boot();
api3.scanAccounts();
check(api3.states.get('persist-fable').scopedWalls.fable, undefined, 'expired persisted wall pruned on load, not resurrected');
check(api3.states.get('persist-capacity').capacityEscalation.fable, undefined, 'stale capacity escalation pruned on load, not resurrected');

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

// --- fable-scope current persistence to .claudeb-state-fable --------------
const fableFile = path.join(fixture, '.claudeb-state-fable');
const fsOps = [];
const realWriteFileSync = fs.writeFileSync;
const realRenameSync = fs.renameSync;
fs.writeFileSync = function (file, ...rest) {
  fsOps.push(['write', String(file)]);
  return realWriteFileSync.call(fs, file, ...rest);
};
fs.renameSync = function (from, to) {
  fsOps.push(['rename', String(from), String(to)]);
  return realRenameSync.call(fs, from, to);
};

fs.writeFileSync(dsFile, '{}');
const api5 = boot();
add('fable-a');
add('fable-b');
fs.writeFileSync(disabledFile, fs.readdirSync(tokensDir).filter((name) => name !== 'fable-a' && name !== 'fable-b').join('\n') + '\n');
api5.scanAccounts();
check(api5.getFableCurrent(), 'fable-a', 'initial scan picks a fable current');
check(fs.readFileSync(fableFile, 'utf8'), 'fable-a\n', 'initial fable pick persisted');

api5.switchForScope('fable', 'test', new Set(['fable-a']));
check(api5.getFableCurrent(), 'fable-b', 'fable switch moves the scoped current');
check(fs.readFileSync(fableFile, 'utf8'), 'fable-b\n', 'fable switch persisted');

const fableOpsBefore = fsOps.filter((op) => op[1] === fableFile || op[2] === fableFile).length;
api5.setCurrent(null);
api5.scanAccounts();
api5.switchForScope('general', 'test', new Set([api5.getCurrent()]));
check(fs.readFileSync(fableFile, 'utf8'), 'fable-b\n', 'general rotation leaves the fable file content alone');
check(fsOps.filter((op) => op[1] === fableFile || op[2] === fableFile).length, fableOpsBefore, 'general rotation performs no fable file operations');

check(fsOps.filter((op) => op[0] === 'write' && op[1] === fableFile).length, 0, 'fable state file is never written in place');
const fableRenames = fsOps.filter((op) => op[0] === 'rename' && op[2] === fableFile);
ok(fableRenames.length >= 2, 'fable state file lands via rename');
ok(fableRenames.every((op) => op[1].startsWith(`${fableFile}.`) && op[1].endsWith('.tmp')), 'every fable rename originates from a tmp file');

fs.writeFileSync = realWriteFileSync;
fs.renameSync = realRenameSync;

// --- held-request claim staggering (thundering-herd desync) ---------------
// N pollers held on the same burst, all with current pointing at a freed
// account, must NOT all short-circuit onto it: the fast path is claim-gated.
add('herd-a');
add('herd-b');
fs.writeFileSync(disabledFile, fs.readdirSync(tokensDir).filter((name) => name !== 'herd-a' && name !== 'herd-b').join('\n') + '\n');
api5.claimedUntil.clear();
api5.scanAccounts();
api5.setCurrent('herd-a');
ok(api5.eligibleForScope('herd-a', 'general') && api5.eligibleForScope('herd-b', 'general'), 'herd: both accounts are general-eligible');
const herdPicks = [];
for (let i = 0; i < 3; i += 1) herdPicks.push(api5.selectAccountForScope('general', new Set(), { spreadClaims: true }));
ok(herdPicks.includes('herd-b'), 'herd: held pollers spread onto the sibling, not all onto current');
ok(new Set(herdPicks).size === 2, 'herd: claim staggering engages both recovering accounts');

api5.claimedUntil.clear();
fs.writeFileSync(disabledFile, fs.readdirSync(tokensDir).filter((name) => name !== 'herd-a').join('\n') + '\n');
api5.scanAccounts();
api5.setCurrent('herd-a');
const soloPicks = [];
for (let i = 0; i < 3; i += 1) soloPicks.push(api5.selectAccountForScope('general', new Set(), { spreadClaims: true }));
ok(soloPicks.every((name) => name === 'herd-a'), 'herd: claims never withhold the only eligible account');

// A first-wall env value larger than a later tier must not invert escalation.
process.env.CLAUDEBD_CAPACITY_WALL_FIRST_MS = '600000';
const bigTiers = boot().capacityWallDurationsS;
process.env.CLAUDEBD_CAPACITY_WALL_FIRST_MS = '1000';
ok(bigTiers.every((s, i) => i === 0 || s >= bigTiers[i - 1]), 'capacity wall tiers stay monotonically non-decreasing for an oversized first-wall value');

// Fable capability: proven only by affirmative live evidence, defaulting to
// capable, and NEVER read back from the limits store (that read-back was the
// self-perpetuating frozen loop).
const tiersFile = path.join(fixture, 'account-tiers');
try { fs.unlinkSync(tiersFile); } catch {}
fs.writeFileSync(dsFile, '{}');
fs.writeFileSync(path.join(tokensDir, 'cap'), 'fixture\n', { mode: 0o600 });
fs.writeFileSync(path.join(limitsDir, 'cap.json'), '{}');
// A polluted store value must be ignored entirely — this is the loop the fix breaks.
fs.writeFileSync(mainLimitsFile, JSON.stringify({ vendors: { claude: { accounts: [
  { account: 'cap', rotation: { usable: { fable: false } } }
] } } }));
fs.writeFileSync(disabledFile, fs.readdirSync(tokensDir).filter((name) => name !== 'cap').join('\n') + '\n');
const apiCap = boot();
apiCap.scanAccounts();
check(apiCap.statusPayload().accounts.cap.blocked.fable, null, 'no evidence + polluted store ignored -> fable capable by default');
check(apiCap.states.get('cap').fableIncapableAt, 0, 'polluted store never sets incapability (loop broken)');

apiCap.markPlanIncapable('cap', 403);
ok(apiCap.states.get('cap').fableIncapableAt > 0, 'plan-rejection evidence records a timestamp');
check(apiCap.statusPayload().accounts.cap.blocked.fable, 'no-capability', 'plan-rejection evidence blocks fable');
check(apiCap.statusPayload().accounts.cap.blocked.general, null, 'plan-rejection never blocks general');
const capPersisted = JSON.parse(fs.readFileSync(dsFile, 'utf8'));
ok(typeof capPersisted.accounts.cap.fableIncapable.at === 'number', 'plan-incapability persisted to daemon-state.json');
check(capPersisted.accounts.cap.fableIncapable.status, 403, 'persisted evidence carries the observed status');

const apiCap2 = boot();
apiCap2.scanAccounts();
check(apiCap2.statusPayload().accounts.cap.blocked.fable, 'no-capability', 'plan-incapability is re-derived from evidence, survives restart');

const staleDs = JSON.parse(fs.readFileSync(dsFile, 'utf8'));
staleDs.accounts.cap.fableIncapable.at = now - 200000;
fs.writeFileSync(dsFile, JSON.stringify(staleDs));
const apiCap3 = boot();
apiCap3.scanAccounts();
check(apiCap3.statusPayload().accounts.cap.blocked.fable, null, 'stale evidence-free false decays back to capable');

fs.writeFileSync(dsFile, '{}');
const apiCap4 = boot();
apiCap4.scanAccounts();
apiCap4.markRejected('cap', {}, 'fable');
check(apiCap4.states.get('cap').fableIncapableAt, 0, 'transient fable 429 never touches capability');
check(apiCap4.statusPayload().accounts.cap.blocked.fable, 'wall', 'transient fable 429 is a temporary wall, not no-capability');

apiCap4.states.get('cap').scopedWalls = {};
apiCap4.states.get('cap').scopedWallReason = {};
fs.writeFileSync(tiersFile, 'cap=20\n');
apiCap4.scanAccounts();
check(apiCap4.statusPayload().accounts.cap.blocked.fable, 'plan', 'tier below the fable minimum is a static plan gate from account-tiers');
check(apiCap4.statusPayload().accounts.cap.blocked.general, null, 'plan tier gate never blocks general');
try { fs.unlinkSync(tiersFile); } catch {}

// A daemon-state entry for an account with no token file (a stray backup that
// was briefly in tokens/) must be pruned on load, without dropping real ones.
fs.writeFileSync(dsFile, JSON.stringify({
  accounts: {
    cap: { authFailedUntil: now + 100000 },
    'phantom-backup.json': { authFailedUntil: now + 100000 }
  },
  pinnedAt: {}
}));
const apiPhantom = boot();
ok(apiPhantom.getDaemonState().accounts.cap, 'real account state survives load');
ok(!apiPhantom.getDaemonState().accounts['phantom-backup.json'], 'phantom account absent from tokens/ is pruned on load');

// A warning naming the weekly bucket must teach 5h and nothing else: headers carry no
// weekly percentage, and stamping one walled whole accounts (shared-invariants n).
add('warn', state());
api.updateFromHeaders('warn', {
  'anthropic-ratelimit-unified-status': 'allowed_warning',
  'anthropic-ratelimit-unified-representative-claim': 'seven_day',
  'anthropic-ratelimit-unified-5h-utilization': '0.42',
  'anthropic-ratelimit-unified-5h-reset': String(now + 3600),
  'anthropic-ratelimit-unified-reset': String(now + 400000)
});
check(api.states.get('warn').h5, 42, 'headers still teach the 5h utilization');
check(api.states.get('warn').wk, 0, 'a seven_day warning never invents a weekly percentage');
check(api.states.get('warn').sevenDay, undefined, 'no synthetic seven_day bucket in state');
const warnSnapshot = JSON.parse(fs.readFileSync(path.join(limitsDir, 'warn.json'), 'utf8'));
ok(!('seven_day' in warnSnapshot), 'header learning never persists a seven_day bucket');
api.scanAccounts();
check(api.statusPayload().accounts.warn.blocked.general, null, 'a seven_day warning leaves general usable');
check(api.statusPayload().accounts.warn.blocked.fable, null, 'a seven_day warning leaves fable usable');

// A header-origin weekly reading on disk is synthetic and must be ignored, not obeyed.
fs.writeFileSync(path.join(tokensDir, 'legacy'), 'fixture\n', { mode: 0o600 });
fs.writeFileSync(path.join(limitsDir, 'legacy.json'), JSON.stringify({
  five_hour: { used_percentage: 4, resets_at: now + 3600, as_of: now, origin: 'headers' },
  seven_day: { used_percentage: 100, resets_at: now + 300000, as_of: now, origin: 'headers' },
  auth: { status: 'ok', checked_at: now }
}));
const apiLegacy = boot();
apiLegacy.scanAccounts();
check(apiLegacy.states.get('legacy').wk, 0, 'header-origin weekly percentage is dropped on load');
check(apiLegacy.statusPayload().accounts.legacy.blocked.general, null, 'a synthetic 100 no longer walls general');

// The legitimate channel must keep working: a usage-endpoint reading of the same
// bucket is a real measurement and still blocks routing.
fs.writeFileSync(path.join(limitsDir, 'legacy.json'), JSON.stringify({
  five_hour: { used_percentage: 4, resets_at: now + 3600, as_of: now, origin: 'headers' },
  seven_day: { used_percentage: 100, resets_at: now + 300000, as_of: now, origin: 'usage' },
  auth: { status: 'ok', checked_at: now }
}));
const apiUsage = boot();
apiUsage.scanAccounts();
check(apiUsage.states.get('legacy').wk, 100, 'usage-origin weekly percentage is trusted');
check(apiUsage.statusPayload().accounts.legacy.blocked.general, 'limit-weekly', 'a measured 100 still walls general');

process.stdout.write(`PASS: claudebd decision logic (${assertions} assertions)\n`);
