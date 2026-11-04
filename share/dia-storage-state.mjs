// dia-mcp --storage-state <ws> <url-part> <out.json> [<cookie-host>...]: one Dia tab's login as a Playwright
// storageState — its localStorage plus the cookies (HttpOnly included) of its host and the listed hosts only,
// never the rest of Egor's browser.
import { writeFileSync } from 'node:fs';

const [ws, needle, out, ...extraHosts] = process.argv.slice(2);
const sock = new WebSocket(ws);
const pending = new Map();
let seq = 0;
const send = (method, params = {}, sessionId) =>
	new Promise((resolve, reject) => {
		const id = ++seq;
		pending.set(id, { resolve, reject });
		sock.send(JSON.stringify({ id, method, params, sessionId }));
	});
sock.onmessage = (event) => {
	const msg = JSON.parse(event.data);
	const waiter = pending.get(msg.id);
	if (!waiter) return;
	pending.delete(msg.id);
	if (msg.error) waiter.reject(new Error(msg.error.message));
	else waiter.resolve(msg.result);
};
const fail = (text) => {
	process.stderr.write(`dia-mcp: ${text}\n`);
	process.exit(1);
};
await new Promise((resolve) => {
	sock.onopen = resolve;
	sock.onerror = () => fail('no connection to Dia (debugging off, or Egor pressed Deny)');
});

const { targetInfos } = await send('Target.getTargets');
const tabs = targetInfos.filter((t) => t.type === 'page' && t.url.includes(needle));
if (tabs.length !== 1) fail(`${tabs.length} Dia tabs match "${needle}"; name one tab`);
const url = new URL(tabs[0].url);
const { sessionId } = await send('Target.attachToTarget', { targetId: tabs[0].targetId, flatten: true });
const { result } = await send(
	'Runtime.evaluate',
	{ expression: 'JSON.stringify(Object.entries(localStorage))', returnByValue: true },
	sessionId,
);
await send('Target.detachFromTarget', { sessionId });

const hosts = [url.hostname, ...extraHosts];
const { cookies } = await send('Storage.getCookies');
const kept = cookies
	.filter((c) => {
		const domain = c.domain.replace(/^\./, '');
		return hosts.some((h) => h === domain || h.endsWith(`.${domain}`));
	})
	.map((c) => ({
		name: c.name,
		value: c.value,
		domain: c.domain,
		path: c.path,
		expires: c.session ? -1 : c.expires,
		httpOnly: c.httpOnly,
		secure: c.secure,
		sameSite: c.sameSite ?? 'Lax',
	}));
const localStorage = JSON.parse(result.value).map(([name, value]) => ({ name, value }));
writeFileSync(out, `${JSON.stringify({ cookies: kept, origins: [{ origin: url.origin, localStorage }] })}\n`, { mode: 0o600 });
process.stderr.write(`${url.origin}: ${localStorage.length} localStorage keys, ${kept.length} cookies (${hosts.join(', ')})\n`);
sock.close();
console.log(out);
