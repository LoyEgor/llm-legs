// mail-find's Apple Mail side (JXA), run by share/mail_find.py: `osascript -l JavaScript mail_find.js '<json>'`.
// The JSON: {words: [..], from: [..], since_ms: epoch|null, accounts: [name|address..]|[], check: bool, body: n|null}.
// Prints JSON: {accounts: [{name, addresses, mailboxes, newest, count}], hits: [{account, mailbox, date, sender,
// subject}], body: text|null}. Words match subject or sender, `from` the sender, all case-insensitively.
// A mailbox is read whole per property: Mail answers `subject of every message` in ~1-2 s for 20k letters, while a
// `whose` filter takes 4-20 s and a range (`messages 1 thru 300`) minutes (measured 2026-11-11).
// Gmail's INBOX is inside its All Mail, so an account with All Mail is read there and in Spam; any other account
// in INBOX, Junk, Spam and Archive.
const FULL = ["All Mail", "Spam", "Junk"];
const PLAIN = ["INBOX", "Junk", "Spam", "Archive"];
// Under this many letters in the window, each is read by index: a --since question then costs one date fetch.
const FEW = 40;

function run(argv) {
  const q = JSON.parse(argv[0]);
  const Mail = Application("Mail");
  if (q.check) Mail.checkForNewMail();
  const want = (q.accounts || []).map((s) => s.toLowerCase());
  const words = (q.words || []).map((s) => s.toLowerCase());
  const from = (q.from || []).map((s) => s.toLowerCase());
  const accounts = [], hits = [];
  for (const acc of Mail.accounts()) {
    const name = acc.name(), addresses = acc.emailAddresses();
    if (want.length && !want.some((w) => w === name.toLowerCase() || addresses.some((a) => a.toLowerCase() === w))) continue;
    const boxes = acc.mailboxes();
    const names = boxes.map((b) => b.name());
    const pick = names.includes("All Mail") ? FULL : PLAIN;
    const row = { name, addresses, mailboxes: [], newest: null, count: 0 };
    boxes.forEach((box, i) => {
      if (!pick.includes(names[i])) return;
      row.mailboxes.push(names[i]);
      const found = search(box, q.since_ms, words, from, 1);
      for (const hit of found.hits) hits.push(Object.assign({ account: name, mailbox: names[i] }, hit));
      if (found.newest !== null && (row.newest === null || found.newest > row.newest)) row.newest = found.newest;
    });
    accounts.push(row);
  }
  hits.sort((a, b) => b.date - a.date);
  accounts.forEach((row) => { row.count = hits.filter((h) => h.account === row.name).length; });
  let body = null;
  if (q.body && hits[q.body - 1]) {
    const h = hits[q.body - 1];
    body = h.ref.content();
  }
  return JSON.stringify({
    accounts: accounts.map((r) => Object.assign(r, { newest: r.newest && r.newest.toISOString() })),
    hits: hits.map((h) => ({ account: h.account, mailbox: h.mailbox, date: h.date.toISOString(), sender: h.sender,
                             subject: h.subject })),
    body,
  });
}

function matches(subject, sender, words, from) {
  const s = (subject || "").toLowerCase(), f = (sender || "").toLowerCase();
  return words.every((w) => s.includes(w) || f.includes(w)) && from.every((w) => f.includes(w));
}

// -> {hits, newest}: the matching letters and the newest date the mailbox holds (null when empty).
function search(box, since, words, from, retries) {
  const msgs = box.messages;
  const dates = msgs.dateReceived();
  const out = [];
  const idx = [];
  let newest = null;
  dates.forEach((d, i) => {
    if (newest === null || d > newest) newest = d;
    if (since === null || since === undefined || d.getTime() >= since) idx.push(i);
  });
  if (idx.length === 0) return { hits: out, newest };
  if (idx.length <= FEW && idx.length < dates.length) {
    for (const i of idx) {
      const m = msgs[i];
      const subject = m.subject(), sender = m.sender();
      if (matches(subject, sender, words, from)) out.push({ date: m.dateReceived(), sender, subject, ref: m });
    }
    return { hits: out, newest };
  }
  const subjects = msgs.subject(), senders = msgs.sender();
  // A letter arriving between the fetches shifts the lists against each other: read again once.
  if ((subjects.length !== dates.length || senders.length !== dates.length) && retries > 0) {
    return search(box, since, words, from, retries - 1);
  }
  for (const i of idx) {
    if (matches(subjects[i], senders[i], words, from)) {
      out.push({ date: dates[i], sender: senders[i], subject: subjects[i], ref: msgs[i] });
    }
  }
  return { hits: out, newest };
}
