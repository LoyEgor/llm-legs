"""mail-find (share/mail_find.py): hits, freshness lines, the NEXT web step and today's web-only answer, on a faked Mail,
pgrep, open and dia-js."""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "share"))
import mail_find  # noqa: E402

NOW = datetime.now(timezone.utc)


def iso(delta):
    return (NOW - delta).isoformat().replace("+00:00", "Z")


def stub(path, body):
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)
    return str(path)


class MailFindTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        (self.dir / "browse").mkdir()
        (self.dir / "browse" / "accounts.json").write_text(json.dumps({
            "notcom": {"email": "loyegor@gmail.com", "chrome_profile": "Profile 10", "status": "ok"},
            "com": {"email": "loyegor.com@gmail.com", "chrome_profile": "Profile 1", "status": "ok"}}))
        self.reply = self.dir / "reply.json"
        self.query = self.dir / "query.json"
        self.opened = self.dir / "opened"
        env = {
            "WORKER_RUN_DIR": str(self.dir),
            "MAIL_FIND_MAILBOXES": str(self.dir / "mailboxes.json"),
            "MAIL_FIND_OSASCRIPT": stub(self.dir / "osascript", f'if [ "$1" = -e ]; then echo "$2" >> "{self.dir}/quits"; '
                                        f'else printf "%s" "$4" > "{self.query}"; cat "{self.reply}"; fi'),
            "MAIL_FIND_PGREP": stub(self.dir / "pgrep", f'[ -e "{self.dir}/running" ]'),
            "MAIL_FIND_OPEN": stub(self.dir / "open", f'echo "$@" > "{self.opened}"; touch "{self.dir}/running"'),
            "MAIL_FIND_DIA_JS": stub(self.dir / "dia-js", f'cat "{self.dir}/tabs" 2>/dev/null'),
        }
        patcher = patch.dict(os.environ, env)
        patcher.start()
        patch.object(mail_find, "MAILBOXES", env["MAIL_FIND_MAILBOXES"]).start()
        self.addCleanup(patch.stopall)
        self.addCleanup(patcher.stop)

    def mail(self, hits=(), newest=timedelta(minutes=5), running=True):
        if running:
            (self.dir / "running").touch()
        self.reply.write_text(json.dumps({"hits": list(hits), "body": None, "accounts": [
            {"name": "LoyEgor@gmail.com", "addresses": ["LoyEgor@gmail.com"], "mailboxes": ["All Mail", "Spam"],
             "newest": iso(newest), "count": len(hits)}]}))

    def run_tool(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = mail_find.main(list(argv))
        return code, out.getvalue().strip().splitlines()

    def test_hit_prints_no_next_and_exits_0(self):
        self.mail([{"account": "LoyEgor@gmail.com", "mailbox": "All Mail", "date": iso(timedelta(minutes=20)),
                    "sender": "a@b.c", "subject": "Invoice"}])
        code, lines = self.run_tool("invoice", "from:a@b.c", "--since", "3d")
        self.assertEqual(code, 0)
        self.assertIn("a@b.c  Invoice  [LoyEgor@gmail.com/All Mail]", lines[0])
        self.assertTrue(lines[-1].startswith("FRESH: LoyEgor@gmail.com: Mail was running; newest letter"))
        self.assertFalse(any(line.startswith("NEXT:") for line in lines))
        self.assertFalse((self.dir / "quits").exists())  # a Mail already running stays
        query = json.loads(self.query.read_text())
        self.assertEqual((query["words"], query["from"], query["check"]), (["invoice"], ["a@b.c"], False))

    def test_todays_mail_is_read_on_the_web_and_mail_stays_closed(self):
        self.mail(running=False)
        code, lines = self.run_tool("invoice", "--since", "1h")
        self.assertEqual(code, 1)
        self.assertFalse(self.opened.exists() or self.query.exists())
        head = "NEXT: a letter of the last 1 h is read on the web, Mail is not opened for it: "
        # no Mail read yet: every pool mailbox
        self.assertEqual(lines, [head + "ACCOUNT: com BROWSER: chrome", head + "ACCOUNT: notcom BROWSER: chrome"])
        # after one: Mail's own accounts
        (self.dir / "running").touch()
        self.run_tool("invoice", "--since", "3d")
        _, lines = self.run_tool("invoice", "--since", "1d")
        self.assertEqual(lines, ["NEXT: a letter of the last 24 h is read on the web, Mail is not opened for it: "
                                 "ACCOUNT: notcom BROWSER: chrome"])

    def test_open_dia_tab_of_that_mailbox_is_named(self):
        self.mail()
        (self.dir / "tabs").write_text("T1\t0\thttps://mail.google.com/mail/u/0/#inbox\t"
                                       "Inbox - loyegor@gmail.com - Gmail\n")
        _, lines = self.run_tool("invoice", "--since", "2h")
        self.assertTrue(lines[-1].endswith("ACCOUNT: notcom BROWSER: chrome, or Egor's open Dia tab: "
                                           "dia-js --tab-id T1"))

    def test_long_window_with_fresh_mail_needs_no_web(self):
        self.mail(newest=timedelta(minutes=5))
        code, lines = self.run_tool("invoice", "--since", "2d")
        self.assertEqual(code, 1)
        self.assertTrue(lines[-1].startswith("FRESH:"))
        code, lines = self.run_tool("invoice")
        self.assertTrue(lines[-1].startswith("FRESH:"))

    def test_newest_older_than_window_ends_with_next(self):
        self.mail(newest=timedelta(days=3))
        _, lines = self.run_tool("invoice", "--since", "2d")
        self.assertTrue(lines[-1].startswith("NEXT:"))

    def test_closed_mail_is_started_hidden_asked_to_check_and_says_so(self):
        self.mail(newest=timedelta(minutes=5), running=False)
        code, lines = self.run_tool("invoice")
        self.assertEqual(code, 1)
        self.assertEqual(self.opened.read_text().split(), ["-g", "-j", "-a", "Mail"])
        self.assertTrue(json.loads(self.query.read_text())["check"])
        self.assertIn("Mail was closed: started it hidden, it fetched new mail while read", lines[-2])
        self.assertIn("com.apple.mail", (self.dir / "quits").read_text())  # the Mail it started is quit
        self.assertTrue(lines[-1].startswith("NEXT:"))

    def test_pool_account_name_selects_its_mailbox(self):
        self.mail()
        self.run_tool("invoice", "--account", "notcom")
        self.assertEqual(json.loads(self.query.read_text())["accounts"], ["loyegor@gmail.com"])

    def test_mail_error_exits_3(self):
        self.mail()
        os.environ["MAIL_FIND_OSASCRIPT"] = stub(self.dir / "broken", "echo 'not authorized' >&2; exit 1")
        self.assertEqual(self.run_tool("invoice")[0], 3)

    def test_bad_window_and_empty_query_are_refused(self):
        for argv in (["x", "--since", "3w"], []):
            with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
                mail_find.main(argv)
            self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
