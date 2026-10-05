import subprocess
from pathlib import Path


def report_repo_identity(repo):
    proc = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel", "--git-common-dir", "--git-dir"],
                          capture_output=True, text=True)
    fields = proc.stdout.splitlines()
    if proc.returncode != 0 or len(fields) != 3:
        return None
    top, common, git_dir = fields
    project = Path(top).name
    owner = Path(common).resolve().parent.name
    if Path(common).resolve() != Path(git_dir).resolve() and owner and owner != project:
        return f"{owner} ⧉ {project}"
    return project


if __name__ == "__main__":
    print(report_repo_identity("."))
