"""Operating-system boundaries: bounded subprocess I/O, paths, locks.

Nothing in this module talks to CyberGhost or NetworkManager. It is the only
place that spawns processes or takes the per-user lifecycle lock.
"""

import contextlib
import fcntl
import json
import os
import pwd
import re
import selectors
import shutil
import signal
import stat
import subprocess
import time

from .constants import (
    LEGACY_POLKIT_MARKER_CONTENT,
    LEGACY_POLKIT_MARKER_RELATIVE_PATH,
    LIFECYCLE_LOCK_RELATIVE_PATH,
    LIFECYCLE_LOCK_WAIT_SECONDS,
    MAX_HTTP_RESPONSE_BYTES,
    MAX_SUBPROCESS_INPUT_BYTES,
    MAX_SUBPROCESS_OUTPUT_BYTES,
)


def run_bounded(
    command,
    timeout=30,
    input_data=None,
    max_output_bytes=MAX_SUBPROCESS_OUTPUT_BYTES,
    env=None,
):
    """Run a command with a hard output and wall-clock limit."""
    if not command:
        raise ValueError("Command must not be empty")
    argv = [str(part) for part in command]
    if input_data is not None and not isinstance(input_data, bytes):
        input_data = str(input_data).encode("utf-8")
    if input_data is not None and len(input_data) > MAX_SUBPROCESS_INPUT_BYTES:
        raise RuntimeError(f"Command input exceeded {MAX_SUBPROCESS_INPUT_BYTES} bytes")

    # argv is built from absolute system binaries or validated fixed arguments.
    process = subprocess.Popen(  # noqa: S603
        argv,
        stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        env=env,
    )

    selector = selectors.DefaultSelector()
    streams = ((process.stdout, "stdout"), (process.stderr, "stderr"))
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    input_offset = 0
    try:
        for stream, name in streams:
            selector.register(stream, selectors.EVENT_READ, name)
        if process.stdin is not None:
            os.set_blocking(process.stdin.fileno(), False)
            if input_data:
                selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
            else:
                process.stdin.close()

        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(argv, timeout)
            for key, _ in events:
                if key.data == "stdin":
                    try:
                        written = os.write(process.stdin.fileno(), input_data[input_offset:])
                        input_offset += written
                    except BrokenPipeError:
                        input_offset = len(input_data)
                    if input_offset >= len(input_data):
                        selector.unregister(process.stdin)
                        process.stdin.close()
                    continue

                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                total = len(buffers["stdout"]) + len(buffers["stderr"]) + len(chunk)
                if total > max_output_bytes:
                    raise RuntimeError(f"Command output exceeded {max_output_bytes} bytes")
                buffers[key.data].extend(chunk)

        # A child may close both output streams and continue running. Keep the
        # same deadline while waiting for its exit as while reading its output.
        exit_code = process.wait(timeout=max(0, deadline - time.monotonic()))
        return subprocess.CompletedProcess(
            argv,
            exit_code,
            buffers["stdout"].decode("utf-8", errors="replace"),
            buffers["stderr"].decode("utf-8", errors="replace"),
        )
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        selector.close()
        for stream, _ in streams:
            if stream and not stream.closed:
                stream.close()
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()


def read_response_bounded(response, max_bytes=MAX_HTTP_RESPONSE_BYTES, deadline=None):
    """Read a streamed HTTP body with byte and optional wall-clock limits."""
    content_length = response.headers.get("Content-Length")
    if content_length and content_length.isdigit() and int(content_length) > max_bytes:
        response.close()
        raise RuntimeError(f"HTTP response exceeds {max_bytes} bytes")

    chunks = []
    total = 0
    try:
        for chunk in response.iter_content(chunk_size=8192):
            if deadline is not None and time.monotonic() >= deadline:
                raise RuntimeError("HTTP response timed out")
            if not chunk:
                continue
            total += len(chunk)
            if total > max_bytes:
                raise RuntimeError(f"HTTP response exceeds {max_bytes} bytes")
            chunks.append(chunk)
    finally:
        response.close()
    return b"".join(chunks)


def response_json(response):
    """Decode a body captured by read_response_bounded and require an object."""
    try:
        data = json.loads(getattr(response, "_cyberghost_body", b"{}").decode("utf-8"))
    except (AttributeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("CyberGhost returned invalid JSON") from exc
    if not isinstance(data, dict):
        raise RuntimeError("CyberGhost returned an unexpected JSON shape")
    return data


def clean_command_error(text, fallback="Command failed"):
    """Keep user-facing command errors useful without leaking Python tracebacks."""
    raw = str(text or "")[:8192]
    lines = raw.splitlines()
    saw_traceback = "Traceback (most recent call last):" in raw or 'File "' in raw
    for line in reversed(lines):
        clean = line.strip()
        if not clean:
            continue
        # PyInstaller appends this generic footer after the useful exception.
        if re.match(r"\[\d+\] Failed to execute script .*due to unhandled exception!?$", clean):
            continue
        if re.search(r"The key [\"\'](?:password|username)[\"\'] does not exist in section [\"\']account[\"\']", clean):
            return "CyberGhost CLI account setup is incomplete. Run cyberghostvpn --setup in a terminal, then refresh."
        if clean in {
            "Traceback (most recent call last):",
            "During handling of the above exception, another exception occurred:",
            "The above exception was the direct cause of the following exception:",
        }:
            saw_traceback = True
            continue
        if clean.startswith('File "') or clean.startswith("[Previous line repeated") or clean == "^":
            saw_traceback = True
            continue
        if clean.startswith("Error:"):
            clean = clean[6:].strip()
        if saw_traceback and not re.search(
            r"error|exception|failed|unable|certificate|hostname|network|timeout", clean, re.I
        ):
            continue
        if clean:
            return clean[:512]
    return fallback[:512]


def invoking_user():
    return pwd.getpwuid(os.getuid())


def secure_system_file(path, executable=False):
    """Recognize only a regular, root-owned file that others cannot modify."""
    try:
        file_stat = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_uid != 0 or file_stat.st_mode & 0o022:
        return False
    return not executable or bool(file_stat.st_mode & 0o111)


def user_polkit_marker_installed():
    """Read the pre-1.7 installer marker when the system rule is not traversable."""
    path = os.path.join(invoking_user().pw_dir, LEGACY_POLKIT_MARKER_RELATIVE_PATH)
    try:
        marker_stat = os.lstat(path)
        if not stat.S_ISREG(marker_stat.st_mode) or marker_stat.st_uid != os.getuid():
            return False
        with open(path, encoding="ascii") as marker:
            return marker.read(128).strip() == LEGACY_POLKIT_MARKER_CONTENT
    except (OSError, UnicodeError):
        return False


def system_binary(name):
    path = shutil.which(name)
    if not path:
        raise FileNotFoundError(name)
    return path


def system_binary_available(name):
    try:
        system_binary(name)
        return True
    except (FileNotFoundError, RuntimeError):
        return False


class OperationCancelled(BaseException):
    """Cancellation bypasses fallback handlers and is handled at rollback boundaries."""


def _cancel_on_sigterm(signum, frame):
    raise OperationCancelled("Operation cancelled")


@contextlib.contextmanager
def lifecycle_lock(wait=LIFECYCLE_LOCK_WAIT_SECONDS):
    """Serialize connect, disconnect and logout for this user.

    A cancelled or timed-out action may still be rolling back; the next one
    waits for it instead of racing it on the same NetworkManager profile.
    """
    path = os.path.join(invoking_user().pw_dir, LIFECYCLE_LOCK_RELATIVE_PATH)
    with user_file_lock(path, wait):
        yield


@contextlib.contextmanager
def user_file_lock(path, wait=LIFECYCLE_LOCK_WAIT_SECONDS):
    """Bounded lock shared by all writers of a private user-state file."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0), 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != invoking_user().pw_uid or info.st_mode & 0o077:
        os.close(fd)
        raise RuntimeError("Unsafe CyberGhost state lock")
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Another CyberGhost VPN operation is still finishing. Try again.") from None
                time.sleep(0.2)
        yield
    finally:
        os.close(fd)
