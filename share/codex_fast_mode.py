import os
from pathlib import Path
import re
import sys
import tempfile


def main():
    profiles, name, mode = sys.argv[1:4]
    tool = sys.argv[4] if len(sys.argv) > 4 else "codexb"
    if (mode not in {"on", "off", "status", "tier", "state"} or name == "main"
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name)):
        raise ValueError("use a named account and on, off, status, tier, or state")
    target = Path(profiles) / f".{tool}" / "fast-mode" / name
    if mode in {"on", "off"}:
        tier = "fast" if mode == "on" else "default"
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(dir=target.parent)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(tier + "\n")
        os.replace(temporary, target)
    elif target.exists():
        tier = target.read_text().strip()
    else:
        tier = "default"
    if tier not in {"fast", "priority", "default"}:
        raise ValueError("invalid saved Fast Mode state")
    if mode == "state":
        configured = "fast" if tier in {"priority", "fast"} else "default"
        requested = "on" if configured == "fast" else "off"
        print('{"requested":"%s","configured":"%s","backend":"unknown"}' %
              (requested, configured))
    elif mode == "tier":
        if tier == "priority":
            tier = "fast"
        if tier not in {"fast", "default"}:
            raise ValueError("invalid saved Fast Mode override")
        print(tier)
    else:
        print("on" if tier in {"priority", "fast"} else "off")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        tool = sys.argv[4] if len(sys.argv) > 4 else "codexb"
        print(f"{tool}: Fast Mode unavailable: {type(error).__name__}", file=sys.stderr)
        sys.exit(2)
