"""Read keys out of a Chromium extension's `Local Extension Settings/<id>` leveldb, read-only.

    python3 ext_leveldb.py <dir> <key>...   ->   one `<key>\t<value>` line per key found

The value is the newest write across the write-ahead `.log` files and the `.ldb` tables; a key
whose newest write is a deletion prints with an empty value.
A file that does not parse as leveldb (test fixtures, a torn write) is scanned as raw bytes
instead: the line then carries the 150 bytes after the key's last literal occurrence, the shape
the old grep answered with. Python stdlib only; the snappy decompressor is inlined.
"""

import os
import re
import struct
import sys

TABLE_MAGIC = 0xDB4775248B80FB57
LOG_BLOCK = 32768
RAW_WINDOW = 150


def varint(buf, pos):
    result = shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint overflow")


def snappy_decompress(src):
    length, pos = varint(src, 0)
    out = bytearray()
    while pos < len(src):
        tag = src[pos]
        pos += 1
        kind = tag & 3
        if kind == 0:
            size = tag >> 2
            if size >= 60:
                extra = size - 59
                size = int.from_bytes(src[pos:pos + extra], "little")
                pos += extra
            size += 1
            out += src[pos:pos + size]
            pos += size
            continue
        if kind == 1:
            size = ((tag >> 2) & 7) + 4
            offset = ((tag >> 5) << 8) | src[pos]
            pos += 1
        elif kind == 2:
            size = (tag >> 2) + 1
            offset = int.from_bytes(src[pos:pos + 2], "little")
            pos += 2
        else:
            size = (tag >> 2) + 1
            offset = int.from_bytes(src[pos:pos + 4], "little")
            pos += 4
        if offset == 0 or offset > len(out):
            raise ValueError("bad snappy offset")
        start = len(out) - offset
        if offset >= size:
            out += out[start:start + size]
        else:
            for i in range(size):
                out.append(out[start + i])
    if len(out) != length:
        raise ValueError("snappy length mismatch")
    return bytes(out)


def read_block(data, offset, size):
    if offset + size + 5 > len(data):
        raise ValueError("block out of range")
    raw = data[offset:offset + size]
    kind = data[offset + size]
    if kind == 0:
        return raw
    if kind == 1:
        return snappy_decompress(raw)
    raise ValueError("unknown block compression")


def block_entries(block):
    if len(block) < 4:
        raise ValueError("short block")
    restarts = struct.unpack_from("<I", block, len(block) - 4)[0]
    end = len(block) - 4 - 4 * restarts
    if end < 0:
        raise ValueError("bad restart count")
    pos, key = 0, b""
    while pos < end:
        shared, pos = varint(block, pos)
        unshared, pos = varint(block, pos)
        vlen, pos = varint(block, pos)
        # Keys are stored as the byte count shared with the PREVIOUS key plus the rest, so the
        # literal key text is absent from the file whenever its neighbour shares a prefix.
        if shared > len(key) or pos + unshared + vlen > end:
            raise ValueError("bad block entry")
        key = key[:shared] + block[pos:pos + unshared]
        pos += unshared
        yield key, block[pos:pos + vlen]
        pos += vlen


def table_lookup(data, wanted, found):
    if len(data) < 48 or struct.unpack_from("<Q", data, len(data) - 8)[0] != TABLE_MAGIC:
        raise ValueError("not a table")
    footer = data[len(data) - 48:]
    _, pos = varint(footer, 0)
    _, pos = varint(footer, pos)
    index_offset, pos = varint(footer, pos)
    index_size, pos = varint(footer, pos)
    handles = []
    for separator, handle in block_entries(read_block(data, index_offset, index_size)):
        offset, hpos = varint(handle, 0)
        size, _ = varint(handle, hpos)
        handles.append((separator[:-8], offset, size))
    previous = None
    for separator, offset, size in handles:
        if any(key <= separator and (previous is None or previous <= key) for key in wanted):
            for internal, value in block_entries(read_block(data, offset, size)):
                user, trailer = internal[:-8], internal[-8:]
                if user in wanted and len(trailer) == 8:
                    tag = int.from_bytes(trailer, "little")
                    keep(found, user, tag >> 8, value if tag & 0xFF == 1 else None)
        previous = separator


def log_records(data):
    pos, pending = 0, None
    while pos + 7 <= len(data):
        room = LOG_BLOCK - pos % LOG_BLOCK
        if room < 7:
            pos += room
            continue
        size = data[pos + 4] | (data[pos + 5] << 8)
        kind = data[pos + 6]
        if kind == 0 and size == 0:
            pos += room
            continue
        if kind not in (1, 2, 3, 4) or 7 + size > room or pos + 7 + size > len(data):
            raise ValueError("bad log record")
        chunk = data[pos + 7:pos + 7 + size]
        pos += 7 + size
        if kind == 1:
            yield chunk
        elif kind == 2:
            pending = bytearray(chunk)
        elif pending is not None:
            pending += chunk
            if kind == 4:
                yield bytes(pending)
                pending = None


def log_lookup(data, wanted, found):
    batches = 0
    for batch in log_records(data):
        if len(batch) < 12:
            raise ValueError("short write batch")
        sequence = int.from_bytes(batch[:8], "little")
        count = int.from_bytes(batch[8:12], "little")
        pos = 12
        for index in range(count):
            tag = batch[pos]
            klen, pos = varint(batch, pos + 1)
            key = batch[pos:pos + klen]
            pos += klen
            value = None
            if tag == 1:
                vlen, pos = varint(batch, pos)
                value = batch[pos:pos + vlen]
                pos += vlen
            elif tag != 0:
                raise ValueError("bad batch tag")
            if key in wanted:
                keep(found, key, sequence + index, value)
        batches += 1
    if batches == 0 and data.strip(b"\0"):
        raise ValueError("no log records")


def keep(found, key, sequence, value):
    if key not in found or found[key][0] < sequence:
        found[key] = (sequence, value)


def raw_scan(data, wanted, raw):
    for key in wanted:
        hits = [m.end() for m in re.finditer(re.escape(key), data)]
        if hits:
            raw[key] = data[hits[-1]:hits[-1] + RAW_WINDOW]


def text(value):
    return re.sub(r"[\x00-\x1f\x7f]", "", value.decode("utf-8", "replace"))


def lookup(directory, keys):
    wanted = {key.encode() for key in keys}
    found, raw = {}, {}
    names = sorted(os.listdir(directory)) if os.path.isdir(directory) else []
    files = [n for n in names if n.endswith(".ldb")] + [n for n in names if n.endswith(".log")]
    for name in files:
        try:
            with open(os.path.join(directory, name), "rb") as handle:
                data = handle.read()
        except OSError:
            continue
        parsed = {}
        try:
            (table_lookup if name.endswith(".ldb") else log_lookup)(data, wanted, parsed)
        except (ValueError, IndexError, struct.error):
            raw_scan(data, wanted, raw)
            continue
        for key, (sequence, value) in parsed.items():
            keep(found, key, sequence, value)
    result = {}
    for key in keys:
        encoded = key.encode()
        if encoded in found:
            value = found[encoded][1]
            result[key] = "" if value is None else text(value)
        elif encoded in raw:
            result[key] = text(raw[encoded])
    return result


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: ext_leveldb.py <dir> <key>...\n")
        return 2
    for key, value in lookup(argv[1], argv[2:]).items():
        sys.stdout.write(f"{key}\t{value}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
