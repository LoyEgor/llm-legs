import contextlib
import io
import sys
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
