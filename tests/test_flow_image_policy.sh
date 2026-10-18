#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT" <<'PY'
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
checks = 0


def check(condition, detail):
    global checks
    checks += 1
    assert condition, detail


with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    env = dict(os.environ, HOME=str(work), CLAUDEB_DIR=str(work / "store"),
               GEMINI_WEB_DIR=str(work / "web"), IMAGE_LEG_LOG=str(work / "legs.jsonl"),
               PYTHONDONTWRITEBYTECODE="1", IMAGE_LEG_CLI_OK="1",
               STATUSLINE_CACHE_DIR=str(work / "statusline"))
    env["UV_CACHE_DIR"] = subprocess.check_output(["uv", "cache", "dir"], text=True).strip()
    os.environ.update(env)
    sys.path.insert(0, str(root / "share"))
    import flow_image as fi

    def account_boundary(*args, **kwargs):
        raise AssertionError("policy reached account selection")

    fi.gw.take_accounts = account_boundary
    fi.gw.bound_accounts = account_boundary
    base = dict(prompt="a vase", out_dir=str(work), model="pro", aspect=None, count=1,
                ref=[], upscale=None, resume=None, account=None, timeout=None, dry_run=False, lock_wait=0)
    for override in ({}, {"account": "com"}, {"count": 4}, {"model": "nb2"},
                     {"resume": "saved", "account": "com"}, {"dry_run": True}):
        try:
            fi.cmd_generate(argparse.Namespace(**{**base, **override}))
            raise AssertionError("ordinary Flow image accepted")
        except fi.gw.Failure as failure:
            check(failure.code == 2 and "Flow video-first" in failure.reason
                  and "media-run image" in failure.reason, failure.reason)
    for op in ("inpaint", "outpaint", "cutout"):
        try:
            fi.cmd_tool(argparse.Namespace(op=op))
            raise AssertionError("ordinary Flow edit accepted")
        except fi.gw.Failure as failure:
            check(failure.code == 2, failure.reason)

    plans = []
    fi.gw.take_accounts = lambda *args: ["fixture"]
    fi.gw.take_failover = lambda accounts, plan, *args, **kwargs: plans.append(plan)
    fi.cmd_generate(argparse.Namespace(**{**base, "upscale": "2k"}))
    check(len(plans) == 1 and plans[0]["upscale"] == "2k", plans)

    engine = work / "engine"
    engine.write_text(f'#!/bin/sh\nexec "{sys.executable}" -B "{root}/share/flow_image.py" "$@"\n')
    engine.chmod(0o755)
    env["FLOW_IMAGE_ENGINE"] = str(engine)
    refused = subprocess.run(["bash", str(root / "bin/gemini-image"), "--dest", str(work / "image.png"),
                              "--prompt", "a vase"], env=env, text=True, capture_output=True)
    check(refused.returncode == 2, refused.stderr)
    check(len(refused.stderr.splitlines()) == 1 and "Flow video-first" in refused.stderr
          and "media-run image" in refused.stderr, refused.stderr)
    check("USAGE_LIMIT" not in refused.stderr and "fallback_from=" not in refused.stdout, refused)

    fixtures = work / "bin"
    fixtures.mkdir()
    calls = work / "calls"
    for vendor in ("codex", "gemini", "grok"):
        for kind in ("image", "video"):
            stub = fixtures / f"{vendor}-{kind}"
            stub.write_text(f'#!/bin/sh\necho "{vendor}-{kind}" >>"{calls}"\n'
                            'while [ "$#" -gt 0 ]; do\n'
                            '  if [ "$1" = --dest ]; then dest=$2; shift 2; else shift; fi\n'
                            'done\nprintf image >"$dest"\nprintf "size=64x64\\naccount=fixture\\n"\n')
            stub.chmod(0o755)
    for name in ("chatgpt-web", "gemini-web", "grokb"):
        stub = fixtures / name
        stub.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"accounts":[{"account":"fixture","login":true}]}\'\n')
        stub.chmod(0o755)
    env.update(IMAGE_FANOUT_BIN_DIR=str(fixtures), IMAGE_FANOUT_LISTER_DIR=str(fixtures),
               IMAGE_FANOUT_LAUNCH_GAP_MS="0")

    def fanout(*args, media=False):
        prefix = ["bash", str(root / "bin/media-run"), "image"] if media else ["bash", str(root / "bin/image-fanout")]
        command = prefix + list(args)
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        check(result.returncode == 0, (command, result.stdout, result.stderr))
        return result.stdout

    for vendors in ("all", "codex,gemini"):
        out = fanout("--dest-dir", str(work), "--prompt", "a vase", "--vendors", vendors, "--dry-run")
        check("gemini -\tskipped: Flow video-first" in out and "gemini-image" not in out, out)
        check("codex-image" in out, out)
    out = fanout("--vendors", "codex,gemini", "--takes", "2", "--", "--dest-dir", str(work),
                 "--prompt", "a vase", "--dry-run", media=True)
    check("gemini -\tskipped: Flow video-first" in out and "gemini-image" not in out, out)

    jobs = work / "jobs.jsonl"
    jobs.write_text("\n".join(json.dumps(dict(prompt="a vase", dest=str(work / f"job{i}.png"),
                                              vendor="codex,gemini", **extra))
                              for i, extra in enumerate(({}, {"upscale": "2k"}))) + "\n")
    out = fanout("--jobs", str(jobs), "--", "--dest-dir", str(work), "--dry-run", media=True)
    check(out.count("gemini -\tskipped: Flow video-first") == 1, out)
    check("gemini-image" in out and "--upscale 2k" in out and "codex-image" in out, out)
    out = fanout("--dest-dir", str(work), "--prompt", "a vase", "--vendors", "gemini", "--takes", "2",
                 "--upscale", "2k", "--spare", "0", "--dry-run")
    check("gemini-image" in out and "--upscale 2k" in out and "--count 2" in out, out)
    ref = work / "ref.ppm"
    ref.write_bytes(b"P6\n2 1\n255\n\xff\x00\x00\x00\x00\x00")
    out = fanout("--dest-dir", str(work), "--prompt", "motion", "--vendors", "gemini", "--video",
                 "--ref", str(ref), "--dry-run")
    check("gemini-video" in out and "Flow video-first" not in out, out)
    out = fanout("--dest-dir", str(work), "--prompt", "a vase", "--vendors", "codex,gemini", "--takes", "1", "--spare", "0")
    check("ok=1 skipped=1 usage_limit=0 failed=0" in out, out)
    check(calls.read_text().splitlines() == ["codex-image"], calls.read_text())

print(f"PASS: {checks} assertions; Flow video-first refuses before accounts, skips ordinary image jobs, keeps 2K and video")
PY
