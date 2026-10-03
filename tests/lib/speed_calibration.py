"""The 2026-09-29 .. 10-02 calibration transcripts folded into <work>/harness by Harness's own C1 reader."""
import glob, gzip, importlib.machinery, importlib.util, json, os, sys

LO, HI = 1790629200, 1790967000


def harness(root):
    loader = importlib.machinery.SourceFileLoader("harness_doctor", os.path.join(root, "bin", "harness-doctor"))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
    loader.exec_module(module)
    return module


def scan(h, root, work):
    """Every event Harness's C1 reader takes from the calibration transcripts, staged under <work>/projects."""
    projects = os.path.join(work, "projects", "p")
    os.makedirs(projects)
    for name in glob.glob(os.path.join(root, "tests", "fixtures", "speed-calibration", "*.jsonl.gz")):
        data = gzip.open(name).read()
        path = os.path.join(projects, os.path.basename(name)[:-3])
        with open(path, "wb") as handle:
            handle.write(data)
        last = h.iso_epoch(json.loads(data.rstrip(b"\n").rsplit(b"\n", 1)[-1])["timestamp"])
        os.utime(path, (last, last))
    os.environ.update(CLAUDE_PROJECTS_DIR=os.path.dirname(projects), HARNESS_DOCTOR_BOOTS="1790882097",
                      HARNESS_DOCTOR_DIR=os.path.join(work, "harness"))
    events = []
    h.scan_transcripts({}, HI + 3600, events, {})
    return events


def fold(h, root, work):
    events = scan(h, root, work)
    h.append_events([e for e in events if e[0] in ("t", "d", "s") and LO <= e[1] < HI])


if __name__ == "__main__":
    fold(harness(sys.argv[1]), sys.argv[1], sys.argv[2])
