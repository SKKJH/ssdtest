#!/usr/bin/env python3
"""Create real data files for capacity pressure or later deletion.

The script writes actual bytes, not sparse files and not fallocate-only extents.
It records every created file into a TSV manifest so del_work.py can delete them
in a controlled, rate-limited way.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import signal
import time
from pathlib import Path

_STOP_REQUESTED = False


def _handle_stop(signum, frame):  # type: ignore[no-untyped-def]
    global _STOP_REQUESTED
    _STOP_REQUESTED = True


signal.signal(signal.SIGTERM, _handle_stop)
signal.signal(signal.SIGINT, _handle_stop)


def parse_size(s: str) -> int:
    raw = s.strip().lower()
    if raw.endswith('k'):
        return int(float(raw[:-1]) * 1024)
    if raw.endswith('m'):
        return int(float(raw[:-1]) * 1024**2)
    if raw.endswith('g'):
        return int(float(raw[:-1]) * 1024**3)
    return int(float(raw))


def human(n: int) -> str:
    if n >= 1024**3:
        return f"{n / 1024**3:.2f}GiB"
    if n >= 1024**2:
        return f"{n / 1024**2:.2f}MiB"
    if n >= 1024:
        return f"{n / 1024:.2f}KiB"
    return str(n)


def write_log(path: Path | None, msg: str) -> None:
    line = f"[{time.strftime('%F %T')}] {msg}\n"
    if path is not None:
        with path.open('a', encoding='utf-8') as f:
            f.write(line)
    print(line, end='', flush=True)


def make_buffer(seed: int, size: int = 1024 * 1024) -> bytes:
    rnd = random.Random(seed)
    try:
        return rnd.randbytes(size)
    except AttributeError:  # Python < 3.9
        return bytes(rnd.randrange(0, 256) for _ in range(size))


def write_file(path: Path, size: int, buf: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    remaining = size
    view = memoryview(buf)
    with path.open('wb', buffering=0) as f:
        while remaining > 0:
            n = min(remaining, len(buf))
            f.write(view[:n])
            remaining -= n


def atomic_write_json(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding='utf-8')
    os.replace(tmp, path)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--base-dir', required=True)
    p.add_argument('--manifest', required=True)
    p.add_argument('--summary', required=True)
    p.add_argument('--dir-count', type=int, required=True)
    p.add_argument('--seed', type=int, required=True)
    p.add_argument('--target-bytes', type=int, required=True)
    p.add_argument('--sizes', required=True)
    p.add_argument('--weights', required=True)
    p.add_argument('--stop-file')
    p.add_argument('--log')
    p.add_argument('--progress-sec', type=float, default=5.0)
    p.add_argument('--sync-at-end', action=argparse.BooleanOptionalAction, default=True)
    args = p.parse_args()

    base = Path(args.base_dir).resolve()
    manifest = Path(args.manifest)
    summary = Path(args.summary)
    stop_file = Path(args.stop_file) if args.stop_file else None
    log_path = Path(args.log) if args.log else None

    if args.dir_count < 1:
        raise SystemExit('--dir-count must be >= 1')
    if args.target_bytes < 0:
        raise SystemExit('--target-bytes must be >= 0')

    sizes = [parse_size(x) for x in args.sizes.split(',') if x.strip()]
    weights = [float(x) for x in args.weights.split(',') if x.strip()]
    if not sizes:
        raise SystemExit('no sizes specified')
    if len(weights) != len(sizes):
        raise SystemExit('weights length must match sizes length')
    if min(sizes) <= 0:
        raise SystemExit('sizes must be positive')

    rnd = random.Random(args.seed)
    buf = make_buffer(args.seed ^ 0xA51CE)
    base.mkdir(parents=True, exist_ok=True)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    summary.parent.mkdir(parents=True, exist_ok=True)
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)

    for i in range(args.dir_count):
        (base / f"d{i:04d}").mkdir(parents=True, exist_ok=True)

    bytes_written = 0
    files = 0
    start = time.monotonic()
    next_progress = start
    stop_reason = 'target_reached'

    write_log(log_path, f"start create base={base} target={args.target_bytes} ({human(args.target_bytes)}) sizes={sizes} weights={weights}")

    with manifest.open('w', encoding='utf-8') as mf:
        mf.write('# relpath\tsize\n')
        while bytes_written < args.target_bytes:
            if _STOP_REQUESTED:
                stop_reason = 'signal'
                break
            if stop_file is not None and stop_file.exists():
                stop_reason = 'stop_file'
                break

            size = int(rnd.choices(sizes, weights=weights, k=1)[0])
            if bytes_written + size > args.target_bytes:
                size = args.target_bytes - bytes_written
                if size <= 0:
                    break
            dno = rnd.randrange(args.dir_count)
            rel = Path(f"d{dno:04d}") / f"work_{files:012d}_{size}.bin"
            path = base / rel
            write_file(path, size, buf)
            mf.write(f"{rel.as_posix()}\t{size}\n")
            if files % 128 == 0:
                mf.flush()
                os.fsync(mf.fileno())
            bytes_written += size
            files += 1

            now = time.monotonic()
            if now >= next_progress:
                elapsed = now - start
                rate = bytes_written / elapsed if elapsed > 0 else 0
                write_log(log_path, f"progress files={files} bytes={bytes_written} ({human(bytes_written)}) rate={human(int(rate))}/s")
                next_progress = now + max(1.0, args.progress_sec)

    if args.sync_at_end:
        write_log(log_path, 'sync created files')
        os.sync()

    elapsed = time.monotonic() - start
    data = {
        'base_dir': str(base),
        'bytes': bytes_written,
        'files': files,
        'target_bytes': args.target_bytes,
        'elapsed_sec': elapsed,
        'stop_reason': stop_reason,
        'sizes': sizes,
        'weights': weights,
        'sync_at_end': args.sync_at_end,
    }
    atomic_write_json(summary, data)
    write_log(log_path, f"done files={files} bytes={bytes_written} ({human(bytes_written)}) elapsed={elapsed:.2f}s stop_reason={stop_reason}")


if __name__ == '__main__':
    main()

