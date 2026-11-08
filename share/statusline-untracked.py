#!/usr/bin/env python3
"""Line count of a repository's untracked files for bin/statusline.sh.

stdin: `git ls-files --others --exclude-standard -z` of <top>, or with a third argument `status` the
render's `git status --porcelain=v2` text; prints `<lines>\t0\t\tU<files>`.
Each file's `grep -cI ''` is cached per repository on its (dev, inode, size, mtime, ctime): a
cache of file content only, pruned to the files listed now. Runs under `python3 -E -S` on every
render, so it imports builtin modules only (marshal, zlib) and subprocess only when it greps.
"""
import marshal
import os
import sys
import time
import zlib

MAX_ENTRIES = 50000
STALE_SECS = 7 * 86400
BATCH = 256


def stamp(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def grep_counts(top, names):
    import subprocess
    counts = {}
    for offset in range(0, len(names), BATCH):
        out = subprocess.run([b'grep', b'-HcI', b'', b'--', *names[offset:offset + BATCH]], cwd=top,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        for line in out.split(b'\n'):
            name, sep, value = line.rpartition(b':')
            if sep and value.isdigit():
                counts[name] = int(value)
    return counts


def load(cache_file):
    try:
        with open(cache_file, 'rb') as stream:
            cache = marshal.load(stream)
    except (OSError, ValueError, EOFError, TypeError):
        return {}
    return cache if isinstance(cache, dict) else {}


def save(cache_dir, cache_file, cache):
    tmp = f'{cache_file}.tmp.{os.getpid()}'
    try:
        os.makedirs(cache_dir, exist_ok=True)
        with open(tmp, 'wb') as stream:
            marshal.dump(cache, stream)
        os.replace(tmp, cache_file)
    except (OSError, ValueError):
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return
    cutoff = time.time() - STALE_SECS
    try:
        for entry in os.scandir(cache_dir):
            if entry.path != cache_file and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                os.unlink(entry.path)
    except OSError:
        pass


def cached_total(top, names, cache_dir):
    # A crc32 clash only shares a file between two repositories: entries are keyed on dev+inode.
    cache_file = os.path.join(cache_dir, '%08x.cache' % zlib.crc32(top))
    # Every stamp of the listing as one string: the same as the last clean run's, its total stands and
    # the per-file cache is never unpacked (20 ms for 8 000 files, as long as the stats themselves).
    sigs = [stamp(os.path.join(top, name)) for name in names]
    listing = marshal.dumps((names, sigs))
    try:
        with open(cache_file + '.sum', 'rb') as stream:
            last_listing, last_total = marshal.load(stream)
        if last_listing == listing and type(last_total) is int:
            return last_total
    except (OSError, ValueError, EOFError, TypeError):
        pass
    old = load(cache_file)
    fresh, total, misses, clean = {}, 0, [], True
    for name, sig in zip(names, sigs):
        record = old.get(name)
        if (sig is not None and type(record) is tuple and len(record) == 2 and record[0] == sig
                and type(record[1]) is int):
            total += record[1]
            if len(fresh) < MAX_ENTRIES:
                fresh[name] = record
        else:
            misses.append((name, sig))
    counts = grep_counts(top, [name for name, _ in misses]) if misses else {}
    for name, sig in misses:
        count = counts.get(name, 0)
        total += count
        # A write racing grep must not file the old count under the new file's stamp.
        if stamp(os.path.join(top, name)) != sig:
            clean = False
        elif sig is not None and len(fresh) < MAX_ENTRIES:
            fresh[name] = (sig, count)
    if fresh != old:
        save(cache_dir, cache_file, fresh)
    if clean:
        save(cache_dir, cache_file + '.sum', (listing, total))
    return total


def xargs_total(top, names):
    import subprocess
    out = subprocess.run(['xargs', '-0', 'grep', '-cI', ''], input=b'\0'.join(names) + b'\0', cwd=top,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    total = 0
    for line in out.split(b'\n'):
        value = line.rsplit(b':', 1)[-1]
        digits = value[1:] if value.startswith(b'-') else value
        if value and value.strip(b'0123456789-') == b'':
            head = digits[:len(digits) - len(digits.lstrip(b'0123456789'))]
            total += (-1 if value.startswith(b'-') else 1) * int(head) if head else 0
    return total


def main():
    top, cache_dir = os.fsencode(sys.argv[1]), sys.argv[2]
    data = sys.stdin.buffer.read()
    # `status`: stdin is the render's `git status --porcelain=v2` text, its `? ` lines the listing.
    names = ([line[2:] for line in data.split(b'\n') if line.startswith(b'? ')] if sys.argv[3:] == ['status']
             else [name for name in data.split(b'\0') if name])
    # grep reads a leading `-` as an option and prints a newline inside a name: the uncached
    # xargs pass keeps what that did to the count.
    if any(name.startswith(b'-') or b'\n' in name for name in names):
        total = xargs_total(top, names)
    else:
        total = cached_total(top, names, cache_dir)
    print(f'{total}\t0\t\tU{len(names)}')


if __name__ == '__main__':
    main()
