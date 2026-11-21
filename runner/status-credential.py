#!/usr/bin/env python3
"""The single private, expiring native-admission credential boundary."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("routing", HERE / "merge-routing.py")
routing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routing)
REPOSITORY = "autumngarage/hesperus"
PERMISSIONS = {"actions": "read", "contents": "read", "pull_requests": "read", "statuses": "write", "metadata": "read"}
DESTINATION = Path("/var/lib/hesperus-runscaler/native-credential/status.json")
require = routing.require


def validate(document, now=None, allow_expired=False):
    now = time.time() if now is None else now
    policy = routing.POLICY[REPOSITORY]
    issuer = policy["issuer"]
    require(issuer and issuer.get("creator_type") == "Bot", "verified App is not installed")
    require(isinstance(document, dict), "credential is not an object")
    require(type(document.get("version")) is int and document.get("version") == 1 and document.get("repository") == REPOSITORY
            and document.get("repository_id") == policy["repository_id"], "credential repository/version differs")
    require(all(document.get(key) == issuer[key] for key in ("app_id", "creator_id", "creator_login"))
            and routing.integer(document.get("installation_id")), "credential issuer differs")
    require(document.get("permissions") == PERMISSIONS, "credential scope differs")
    issued, expires = document.get("issued_at"), document.get("expires_at")
    require(type(issued) is int and type(expires) is int and issued <= now + 5
            and 30 * 60 <= expires - issued <= 65 * 60
            and (allow_expired or expires > now + 60), "credential expired or expiry differs")
    token = document.get("token")
    require(isinstance(token, str) and 0 < len(token) <= 4096
            and all(32 < ord(char) < 127 for char in token), "credential token differs")
    return token


def read(path, now=None, allow_expired=False):
    path = Path(path)
    info = path.lstat()
    require(path.is_file() and not path.is_symlink() and info.st_mode & 0o777 in (0o400, 0o600)
            and info.st_uid in (0, os.geteuid()) and info.st_size <= 16 * 1024, "status credential is not private")
    document = json.loads(path.read_text())
    validate(document, now, allow_expired)
    return document


def receive(document, path=DESTINATION, now=None):
    """Called only by the forced SSH command; no caller-selected destination."""
    import fcntl
    now = time.time() if now is None else now
    validate(document, now)
    require(document["expires_at"] >= now + 30 * 60, "received credential expires too soon")
    path = Path(path)
    parent = path.parent
    info = parent.lstat()
    require(parent.is_dir() and not parent.is_symlink() and info.st_uid == os.geteuid()
            and info.st_mode & 0o777 == 0o700, "credential directory is not private")
    # All legitimate updates use this lock, including overlapping launchd recovery.
    with (parent / "receive.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if path.exists() or path.is_symlink():
            # An expired token is replaceable, but malformed/foreign state needs an operator.
            old = read(path, now, allow_expired=True)
            require(document["issued_at"] >= old["issued_at"] and document["expires_at"] >= old["expires_at"], "credential update is older")
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=parent, prefix=".status-", delete=False) as output:
                temporary = Path(output.name)
                json.dump(document, output)
                output.flush()
                os.fsync(output.fileno())
            temporary.replace(path)
            temporary = None
        finally:
            if temporary:
                temporary.unlink(missing_ok=True)
    return {"version": 1, "repository_id": document["repository_id"], "expires_at": document["expires_at"]}


if __name__ == "__main__":
    import sys
    try:
        require(len(sys.argv) == 1 and not os.environ.get("SSH_ORIGINAL_COMMAND"), "receiver accepts no command or path")
        payload = sys.stdin.buffer.read(16 * 1024 + 1)
        require(len(payload) <= 16 * 1024, "credential exceeds bound")
        print(json.dumps(receive(json.loads(payload))))
    except Exception:
        print("native status credential refused; prior credential retained", file=sys.stderr)
        sys.exit(1)
