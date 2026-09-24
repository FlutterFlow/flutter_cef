#!/usr/bin/env python3
"""cef_host starts and stops the way the plugin expects.

Plays the plugin's side of the IPC: listens on a Unix socket, starts cef_host on
a named (persistent) profile and talks to it.
  * Closing the socket is how a host learns its app has gone: it closes its
    browsers and exits, releasing the profile's lock. The shutdown runs on the
    UI thread; FLUTTER_CEF_TEST_WEDGE_UI_ON_SHUTDOWN (honoured by ad-hoc builds
    only) makes it hang there, as a hung GPU wait would, and the host must
    still exit so the next launch doesn't report "locked".
  * A host that can't reach the plugin, or can't open its profile's lock file,
    exits at once with its own status instead of running on unreachable (and
    holding the lock) or reporting the profile as locked.

Usage: host_lifecycle_test.py <path to cef_host.app/Contents/MacOS/cef_host>
"""
import fcntl
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

# Opcodes, see tool/protocol/spec.dart.
OP_READY = 0x02
OP_CREATE_BROWSER = 0x13
OP_CREATED = 0x1C
OP_LOG = 0x04

failures = 0


def check(name, cond, got=None):
    global failures
    print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  (got: {got})"))
    if not cond:
        failures += 1


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError("cef_host closed the socket")
        buf += chunk
    return buf


def wait_for(conn, op, count=1):
    conn.settimeout(30)
    while count > 0:
        (body_len,) = struct.unpack(">I", read_exact(conn, 4))
        body = read_exact(conn, body_len)
        if body[4] == op:
            count -= 1


def send(conn, browser_id, op, payload=b""):
    conn.sendall(struct.pack(">IIB", 5 + len(payload), browser_id, op) + payload)


def create_browser(conn, browser_id):
    # {u32 w}{u32 h}{f64 dpr}{utf8 url}
    send(conn, browser_id, OP_CREATE_BROWSER,
         struct.pack(">IId", 320, 240, 1.0) + b"about:blank")


def run(host, wedge, browsers=0):
    """Starts cef_host, opens `browsers` browsers once it is ready, disconnects,
    and returns (seconds until it exited or None, whether it needed the hard
    exit, whether the profile lock is free afterwards)."""
    work = tempfile.mkdtemp(prefix="fcef_hardexit_")
    sock_path = os.path.join(work, "ipc.sock")
    profile = os.path.join(work, "profile")
    os.mkdir(profile, 0o700)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(sock_path)
    listener.listen(1)
    listener.settimeout(30)
    env = dict(os.environ)
    env.pop("FLUTTER_CEF_TEST_WEDGE_UI_ON_SHUTDOWN", None)
    if wedge:
        env["FLUTTER_CEF_TEST_WEDGE_UI_ON_SHUTDOWN"] = "1"
    stderr_path = os.path.join(work, "stderr.log")
    stderr = open(stderr_path, "w")
    proc = subprocess.Popen(
        [host, f"--ipc={sock_path}", f"--profile-dir={profile}"],
        env=env, stdout=subprocess.DEVNULL, stderr=stderr)
    try:
        conn, _ = listener.accept()
        wait_for(conn, OP_READY)
        for i in range(browsers):
            create_browser(conn, i + 1)
        wait_for(conn, OP_CREATED, browsers)
        conn.close()
        t0 = time.monotonic()
        try:
            proc.wait(timeout=40)
            exited_after = time.monotonic() - t0
        except subprocess.TimeoutExpired:
            exited_after = None
        stderr.close()
        with open(stderr_path, errors="replace") as f:
            hard_exit = "still running after shutdown" in f.read()
        with open(os.path.join(profile, ".flutter_cef.lock"), "a") as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                lock_free = True
            except OSError:
                lock_free = False
        return exited_after, hard_exit, lock_free
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        listener.close()


def start_failures(host):
    work = tempfile.mkdtemp(prefix="fcef_start_")
    profile = os.path.join(work, "profile")
    os.mkdir(profile, 0o700)

    # No plugin to talk to.
    for args, what in (
        ([f"--profile-dir={profile}"], "no --ipc"),
        ([f"--ipc={os.path.join(work, 'nobody.sock')}", f"--profile-dir={profile}"],
         "an --ipc socket nobody listens on"),
    ):
        proc = subprocess.Popen([host] + args, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        try:
            status = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            status = None
        check(f"a host started with {what} exits with status 1", status == 1, status)

    # A profile dir whose lock file can't be created is not "locked".
    sock_path = os.path.join(work, "ipc.sock")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(sock_path)
    listener.listen(1)
    listener.settimeout(30)
    missing = os.path.join(work, "no", "such", "dir")
    proc = subprocess.Popen([host, f"--ipc={sock_path}", f"--profile-dir={missing}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    logs = []
    try:
        conn, _ = listener.accept()
        conn.settimeout(10)
        try:
            while True:
                (body_len,) = struct.unpack(">I", read_exact(conn, 4))
                body = read_exact(conn, body_len)
                if body[4] == OP_LOG:
                    logs.append(body[5:].decode("utf-8", "replace"))
        except (EOFError, socket.timeout):
            pass
        status = proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        listener.close()
    check("a profile whose lock file can't be opened exits with status 3", status == 3, status)
    check("  and says why", any(l.startswith("profile-lock-failed") for l in logs), logs)


def main():
    host = sys.argv[1]
    start_failures(host)

    exited, hard_exit, lock_free = run(host, wedge=False)
    check("a healthy host exits cleanly when its IPC closes",
          exited is not None and not hard_exit, (exited, hard_exit))
    check("  and releases the profile lock", lock_free)

    # Shutdown closes the browsers and quits once they have closed.
    exited, hard_exit, lock_free = run(host, wedge=False, browsers=2)
    check("a host with open browsers exits cleanly when its IPC closes",
          exited is not None and not hard_exit, (exited, hard_exit))
    check("  and releases the profile lock", lock_free)

    exited, hard_exit, lock_free = run(host, wedge=True)
    check("a host whose UI thread is wedged still exits when its IPC closes",
          exited is not None and exited < 10 and hard_exit, (exited, hard_exit))
    check("  and releases the profile lock", lock_free)

    print("\nALL host lifecycle TESTS PASSED" if failures == 0
          else f"\n{failures} host lifecycle TEST(S) FAILED")
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
