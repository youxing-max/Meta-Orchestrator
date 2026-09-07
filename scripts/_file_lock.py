#!/usr/bin/env python3
"""fcntl-based advisory file lock around the read-modify-write of
pattern-memory.yaml. Prevents concurrent scripts from interleaving
writes and corrupting state (lost update, double-bumped next_id).

POSIX only (Linux/macOS). On Windows fcntl is unavailable -- the
helper returns a no-op context manager so the script keeps working
without locking. SKILL.md "Concurrency" section calls this out.

Usage as a context manager:

  with file_lock(MEMORY_FILE):
      data = load_memory()
      ...
      save_memory(data)

The lock is released on exit (normal or exceptional).
"""
import contextlib
import os
import sys
import time
from pathlib import Path

try:
    import fcntl
    HAS_FCNTL = True
except ImportError:
    HAS_FCNTL = False


def _pid_alive(pid: int) -> bool:
    """Return True if `pid` looks like a running process on POSIX."""
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False
    return True


@contextlib.contextmanager
def file_lock(path: Path, timeout: float = 5.0, poll: float = 0.05):
    """Acquire an advisory lock on `path.lock` for the duration of the block.

    No-op on Windows (fcntl missing). The lock file is best-effort --
    if we cannot create it, we still proceed (the helper should not be the
    reason a write fails). Stale locks from dead PIDs are reclaimed.
    """
    if not HAS_FCNTL:
        yield
        return

    lock_path = path.with_suffix(path.suffix + ".lock")
    deadline = time.monotonic() + timeout
    fd = None
    try:
        while True:
            try:
                fd = os.open(
                    str(lock_path),
                    os.O_CREAT | os.O_RDWR,
                    0o644,
                )
                break
            except FileExistsError:
                # Stale lock? Try to read the pid and reclaim if dead.
                try:
                    raw = lock_path.read_text().strip()
                    stale_pid = int(raw) if raw.isdigit() else None
                except (OSError, ValueError):
                    stale_pid = None
                if stale_pid and not _pid_alive(stale_pid):
                    try:
                        lock_path.unlink()
                    except OSError:
                        pass
                    continue
                if time.monotonic() >= deadline:
                    # Give up rather than block the hook forever.
                    fd = os.open(
                        str(lock_path),
                        os.O_CREAT | os.O_RDWR,
                        0o644,
                    )
                    break
                time.sleep(poll)

        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Someone else holds the lock; wait briefly then retry.
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        # REFUSE rather than silently yield. If we yielded
                        # here the caller would write to the file believing
                        # they hold the lock, while the actual holder is
                        # still in flight → corrupted writes.
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                        sys.exit(
                            f"REFUSED: lock on {lock_path} held by another "
                            f"process for >{timeout}s"
                        )
                    time.sleep(poll)

        # Record our PID so others can detect a stale lock.
        try:
            os.write(fd, f"{os.getpid()}\n".encode())
        except OSError:
            pass
        yield
    finally:
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass
            # Best-effort unlink so the .lock file does not accumulate.
            # Stale-PID reclaim (lines 67-79) still works on the next acquire
            # because we re-O_CREAT the file if it was missing.
            try:
                os.unlink(lock_path)
            except OSError:
                pass