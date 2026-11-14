import asyncio
import contextlib
import io
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "share"))
import tg_read  # noqa: E402


def parsed(argv):
    """The args main() would hand to its handler, without running it."""
    seen = {}

    def capture(coro):
        seen["args"] = coro.cr_frame.f_locals["args"]
        coro.close()
        return 0

    with patch.object(tg_read.asyncio, "run", capture):
        tg_read.main(argv)
    return seen["args"]


class ParsingTests(unittest.TestCase):
    def test_send_text_and_file_are_exclusive_and_required(self):
        self.assertEqual(parsed(["send", "me", "--text", "hi"]).text, "hi")
        for argv in (["send", "me"], ["send", "me", "--text", "a", "--file", "/x"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                tg_read.main(argv)

    def test_send_refuses_empty_and_oversized_text(self):
        for text in ("", "   ", "a" * 4001):
            with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
                tg_read.main(["send", "me", "--text", text])
            self.assertEqual(caught.exception.code, 2)
        self.assertEqual(parsed(["send", "me", "--text", "a" * 4000]).command, "send")

    def test_send_photos_checked_before_connecting(self):
        photo = str(Path(__file__).resolve())
        self.assertEqual(parsed(["send", "me", "--text", "hi", "--photo", photo, "--photo", photo]).photo, [photo, photo])
        self.assertEqual(parsed(["send", "me", "--text", "hi"]).photo, [])
        bad = (["--photo", "/no/such.png"], ["--photo", "rel.png"], ["--photo", photo] * 11)
        for extra in bad:
            with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
                tg_read.main(["send", "me", "--text", "hi", *extra])
            self.assertEqual(caught.exception.code, 2)
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
            tg_read.main(["send", "me", "--text", "a" * 1025, "--photo", photo])
        self.assertEqual(caught.exception.code, 2)

    def test_send_doc_checked_before_connecting(self):
        doc = str(Path(__file__).resolve())
        self.assertEqual(parsed(["send", "me", "--text", "hi", "--doc", doc]).doc, doc)
        self.assertIsNone(parsed(["send", "me", "--text", "hi"]).doc)
        for extra in (["--doc", "/no/such.crt"], ["--doc", "rel.crt"], ["--doc", doc, "--photo", doc]):
            with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
                tg_read.main(["send", "me", "--text", "hi", *extra])
            self.assertEqual(caught.exception.code, 2)
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
            tg_read.main(["send", "me", "--text", "a" * 1025, "--doc", doc])
        self.assertEqual(caught.exception.code, 2)

    def test_send_as_written_flag(self):
        self.assertFalse(parsed(["send", "me", "--text", "hi"]).as_written)
        self.assertTrue(parsed(["send", "me", "--text", "hi", "--as-written"]).as_written)

    def test_transcribe_defaults(self):
        args = parsed(["transcribe", "/tmp/a.ogg"])
        self.assertEqual((args.audio, args.dest, args.language, args.engine), ("/tmp/a.ogg", None, "ru", "auto"))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            tg_read.main(["transcribe", "/tmp/a.ogg", "--engine", "whisper"])

    def test_voice_transcribe_flag(self):
        self.assertTrue(parsed(["voice", "x", "--dest-dir", "/tmp/d", "--transcribe"]).transcribe)
        self.assertFalse(parsed(["voice", "x", "--dest-dir", "/tmp/d"]).transcribe)


class NormalizeTests(unittest.TestCase):
    def test_yo_and_dashes(self):
        self.assertEqual(tg_read.normalize("Ёлка ещё — да – нет"), ("Елка еще - да - нет", 2, 2))
        self.assertEqual(tg_read.normalize("plain - text"), ("plain - text", 0, 0))


class FallBackTests(unittest.TestCase):
    def test_usage_failures_fall_back(self):
        self.assertTrue(tg_read.should_fall_back(3, ""))
        for output in ("USAGE_LIMIT reached", "not enough credits", "quota_exceeded", "HTTP 402", "status 429"):
            self.assertTrue(tg_read.should_fall_back(1, output), output)

    def test_other_failures_and_success_do_not(self):
        self.assertFalse(tg_read.should_fall_back(0, "credits"))
        self.assertFalse(tg_read.should_fall_back(1, "file not found"))
        self.assertFalse(tg_read.should_fall_back(2, "HTTP 4029 bytes"))



class CallTag(unittest.TestCase):
    def test_a_call_is_tagged_though_it_has_no_text_or_media(self):
        action = type("MessageActionPhoneCall", (), {})
        spoken, missed = action(), action()
        spoken.duration, missed.duration = 123, None
        self.assertEqual(tg_read.media_tag(SimpleNamespace(action=spoken, media=None)), "[call 2 min]")
        self.assertEqual(tg_read.media_tag(SimpleNamespace(action=missed, media=None)), "[missed call]")
        self.assertEqual(tg_read.media_tag(SimpleNamespace(action=None, media=None)), "")


class FakeTg:
    def __init__(self, last):
        self.last, self.from_users = last, []

    async def get_messages(self, entity, limit, from_user=None):
        self.from_users.append(from_user)
        return [SimpleNamespace(date=self.last)] if self.last else []


class AsEgorTests(unittest.TestCase):
    def test_greeting_goes_after_a_message_today_and_the_name_always(self):
        person = SimpleNamespace(first_name="Слава", is_self=False)
        today = datetime.now(timezone.utc)
        self.assertEqual(asyncio.run(tg_read.as_egor(FakeTg(today), person, "Привіт, Славо! Глянь")),
                         ("Глянь", ["name «Славо»", "greeting «Привіт»"]))
        self.assertEqual(asyncio.run(tg_read.as_egor(FakeTg(None), person, "Привіт! Глянь")), ("Привіт! Глянь", []))

    def test_a_group_counts_only_egors_own_messages(self):
        tg = FakeTg(datetime.now(timezone.utc) - timedelta(days=2))
        self.assertEqual(asyncio.run(tg_read.as_egor(tg, SimpleNamespace(title="Team"), "Привіт, Слава")),
                         ("Привіт, Слава", []))
        self.assertEqual(tg.from_users, ["me"])


class FakeEditTg:
    def __init__(self, message):
        self.message, self.edits, self.deletes = message, [], []

    async def get_messages(self, entity, ids):
        return self.message

    async def edit_message(self, entity, message, text, **_):
        self.edits.append(text)
        return SimpleNamespace(edit_date=datetime.now(timezone.utc), date=None)

    async def delete_messages(self, entity, ids, revoke):
        self.deletes.append((ids, revoke))

    async def disconnect(self):
        pass


class EditDeleteTests(unittest.TestCase):
    def run_cmd(self, tg, argv):
        args = parsed(argv)
        handler = tg_read.cmd_edit if args.command == "edit" else tg_read.cmd_delete
        me = SimpleNamespace(is_self=True, first_name="Egor", id=1)
        out, err = io.StringIO(), io.StringIO()
        with patch.object(tg_read, "client", lambda: tg), patch.object(tg_read, "ensure_authorized", AsyncNoop()), \
                patch.object(tg_read, "resolve", AsyncValue(me)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = asyncio.run(handler(args))
        return code, out.getvalue(), err.getvalue()

    def test_edit_of_an_own_message(self):
        tg = FakeEditTg(SimpleNamespace(out=True, message="old"))
        code, out, _ = self.run_cmd(tg, ["edit", "me", "7", "--text", "new — ёж"])
        self.assertEqual((code, tg.edits), (0, ["new - еж"]))
        self.assertIn("edited #7 in Saved Messages at", out)
        tg = FakeEditTg(SimpleNamespace(out=True, message="new"))
        code, _, err = self.run_cmd(tg, ["edit", "me", "7", "--text", "new"])
        self.assertEqual((code, tg.edits), (2, []))
        self.assertIn("nothing to change", err)

    def test_edit_refuses_a_foreign_message(self):
        tg = FakeEditTg(SimpleNamespace(out=False, message="theirs"))
        code, _, err = self.run_cmd(tg, ["edit", "me", "7", "--text", "new"])
        self.assertEqual((code, tg.edits), (2, []))
        self.assertIn("not Egor's own", err)

    def test_delete_without_yes_refuses(self):
        tg = FakeEditTg(SimpleNamespace(out=True, message="x" * 100, media=None, action=None))
        code, out, err = self.run_cmd(tg, ["delete", "me", "7"])
        self.assertEqual((code, tg.deletes), (2, []))
        self.assertIn("x" * 80, out)
        self.assertNotIn("x" * 81, out)
        self.assertIn("add --yes to delete", err)

    def test_delete_with_yes_calls_once_with_the_id(self):
        tg = FakeEditTg(SimpleNamespace(out=True, message="bye"))
        code, out, _ = self.run_cmd(tg, ["delete", "me", "7", "--yes"])
        self.assertEqual((code, tg.deletes), (0, [([7], True)]))
        self.assertEqual(out.strip(), "deleted #7 in Saved Messages")


class AsyncNoop:
    async def __call__(self, *a, **k):
        return None


class AsyncValue:
    def __init__(self, value):
        self.value = value

    async def __call__(self, *a, **k):
        return self.value

if __name__ == "__main__":
    unittest.main()
