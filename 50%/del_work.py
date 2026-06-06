#!/usr/bin/env python3
"""Rate-limited deletion worker for discard/nodiscard comparison.

It deletes files listed in a manifest, but prints progress only every
--progress-sec seconds to avoid noisy 1-second logs.
"""
from __future__ import annotations

import argparse
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


def pid_alive(pid: int | None) -> bool:
    if pid is None or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def load_manifest(manifest: Path, base: Path) -> list[tuple[Path, int]]:
    out: list[tuple[Path, int]] = []
    with manifest.open('r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 2:
                continue
            p = Path(parts[0])
            if not p.is_absolute():
                p = base / p
            try:
                size = int(parts[1])
            except ValueError:
                size = 0
            out.append((p, size))
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--manifest', required=True)
    p.add_argument('--base-dir', required=True)
    p.add_argument('--tick-sec', type=float, required=True)
    p.add_argument('--progress-sec', type=float, default=10.0)
    p.add_argument('--runtime-sec', type=float, required=True)
    p.add_argument('--rate-bytes-per-min', type=int, required=True)
    p.add_argument('--seed', type=int, required=True)
    p.add_argument('--watch-pid', type=int)
    p.add_argument('--log')
    p.add_argument('--sync-at-end', action=argparse.BooleanOptionalAction, default=True)
    args = p.parse_args()

    base = Path(args.base_dir).resolve()
    manifest = Path(args.manifest)
    log_path = Path(args.log) if args.log else None
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)

    entries = load_manifest(manifest, base)
    rnd = random.Random(args.seed)
    rnd.shuffle(entries)

    write_log(
        log_path,
        f"start delete entries={len(entries)} rate={args.rate_bytes_per_min}/min "
        f"({human(args.rate_bytes_per_min)}/min) runtime={args.runtime_sec}s "
        f"watch_pid={args.watch_pid} progress_sec={args.progress_sec}",
    )

    start = time.monotonic()
    deleted_files = 0
    deleted_bytes = 0
    idx = 0
    stop_reason = 'runtime_elapsed'
    next_progress = 0.0

    while True:
        if _STOP_REQUESTED:
            stop_reason = 'signal'
            break
        elapsed = time.monotonic() - start
        if elapsed >= args.runtime_sec:
            stop_reason = 'runtime_elapsed'
            break
        if not pid_alive(args.watch_pid):
            stop_reason = 'watch_pid_exit'
            break
        if idx >= len(entries):
            stop_reason = 'manifest_exhausted'
            break

        allowed = int(args.rate_bytes_per_min * elapsed / 60.0)
        did_any = False
        while idx < len(entries) and deleted_bytes < allowed:
            path, size = entries[idx]
            idx += 1
            try:
                path.unlink()
                deleted_files += 1
                deleted_bytes += max(0, size)
                did_any = True
            except FileNotFoundError:
                deleted_files += 1
                deleted_bytes += max(0, size)
                did_any = True
            except OSError as e:
                write_log(log_path, f"unlink_failed path={path} error={e}")

        now = time.monotonic() - start
        if did_any and now >= next_progress:
            write_log(
                log_path,
                f"progress deleted_files={deleted_files} "
                f"deleted_bytes={deleted_bytes} ({human(deleted_bytes)}) elapsed={now:.2f}s",
            )
            next_progress = now + max(1.0, args.progress_sec)

        time.sleep(max(0.1, args.tick_sec))

    if args.sync_at_end:
        write_log(log_path, 'sync after deletion')
        os.sync()

    elapsed = time.monotonic() - start
    write_log(
        log_path,
        f"done deleted_files={deleted_files} deleted_bytes={deleted_bytes} "
        f"({human(deleted_bytes)}) elapsed={elapsed:.2f}s stop_reason={stop_reason}",
    )


if __name__ == '__main__':
    main()

