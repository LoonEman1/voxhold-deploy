#!/usr/bin/env python3
"""Refresh archive-installed deployment files without touching operator data."""

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tempfile
from urllib.parse import quote
from urllib.request import Request, urlopen

REPOSITORY = "LoonEman1/voxhold-deploy"
STATE = ".deploy-state.json"
HISTORY = ".deploy-backups"
MAX_ARCHIVE = 20 * 1024 * 1024
MAX_CONTENT = 64 * 1024 * 1024
REQUIRED = {"compose.yaml", "update.sh", "backup.sh", "cpu-images.sh", "Caddyfile", "Caddyfile.ip", "VERSION"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or not path.parts:
        raise ValueError(f"Unsafe deployment path: {name}")
    if path.parts[0] in {".env", ".git", "backups", ".last-good.env", STATE, HISTORY, ".deploy-refresh.lock"}:
        raise ValueError(f"Operator data is not a deployment file: {name}")
    target = root.joinpath(*path.parts)
    for candidate in (target, *target.parents):
        if candidate == root:
            break
        if candidate.is_symlink():
            raise ValueError(f"Refusing to replace a symbolic link: {name}")
    return target


def read_archive(data):
    files = {}
    total = 0
    archive_root = None
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts
            if not parts or PurePosixPath(member.name).is_absolute() or ".." in parts or "\\" in member.name:
                raise ValueError("Unsafe archive path")
            if archive_root is None:
                archive_root = parts[0]
            if parts[0] != archive_root:
                raise ValueError("Archive contains multiple roots")
            if member.isdir():
                continue
            if not member.isfile() or len(parts) < 2:
                raise ValueError("Archive contains a link or special file")
            name = "/".join(parts[1:])
            # Validate protected names even though nothing is extracted to disk yet.
            safe_path(Path("/archive"), name)
            if name in files:
                raise ValueError(f"Duplicate archive entry: {name}")
            total += member.size
            if member.size > MAX_ARCHIVE or total > MAX_CONTENT:
                raise ValueError("Deployment archive is too large")
            mode = member.mode & 0o777
            if name.endswith(".sh"):
                mode |= 0o111
            files[name] = (archive.extractfile(member).read(), mode)
    if not REQUIRED <= files.keys():
        raise ValueError("Archive is missing required deployment files")
    return files


def request_bytes(url, limit):
    request = Request(url, headers={"User-Agent": "voxhold-deploy-updater", "Accept": "application/vnd.github+json"})
    with urlopen(request, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Download exceeds the size limit")
    return data


def fetch_release(ref):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}", ref) or ".." in ref:
        raise ValueError("Invalid deployment ref; use a release tag, branch or commit SHA")
    commit = json.loads(request_bytes(f"https://api.github.com/repos/{REPOSITORY}/commits/{quote(ref, safe='')}", 1024 * 1024))["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("GitHub returned an invalid commit SHA")
    files = read_archive(request_bytes(f"https://codeload.github.com/{REPOSITORY}/tar.gz/{commit}", MAX_ARCHIVE))
    return commit, files


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".deploy-write-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_state(root):
    path = root / STATE
    if path.is_symlink():
        raise ValueError("Deployment state must not be a symbolic link")
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def restore(root, backup):
    history = root / HISTORY
    if history.is_symlink() or not backup.resolve().is_relative_to(history.resolve()):
        raise ValueError("Backup must be inside .deploy-backups")
    metadata = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    # Validate the entire backup and current files before restoring anything.
    originals = {}
    for name, item in metadata["files"].items():
        target = safe_path(root, name)
        if target.exists() and digest(target.read_bytes()) != item["installed_sha256"]:
            raise ValueError(f"File changed since refresh; preserve it before rollback: {name}")
        if item["existed"]:
            saved = backup / "files" / name
            if saved.is_symlink() or not saved.resolve().is_relative_to(backup.resolve()):
                raise ValueError("Unsafe backup file")
            data = saved.read_bytes()
            if digest(data) != item["original_sha256"]:
                raise ValueError(f"Corrupt backup: {name}")
            originals[name] = data
    for name, item in metadata["files"].items():
        target = safe_path(root, name)
        if item["existed"]:
            atomic_write(target, originals[name], item["mode"])
        elif target.exists():
            target.unlink()
    if metadata["previous_state"] is None:
        (root / STATE).unlink(missing_ok=True)
    else:
        atomic_write(root / STATE, json.dumps(metadata["previous_state"], indent=2).encode())


def apply_release(root, ref, commit, files, baseline, replace_local=False):
    old_state = load_state(root)
    conflicts = []
    changes = {}
    for name, (data, mode) in files.items():
        target = safe_path(root, name)
        if target.exists() and not target.is_file():
            raise ValueError(f"Deployment path is not a file: {name}")
        current = target.read_bytes() if target.exists() else None
        if current == data:
            continue
        expected = baseline.get(name)
        if ((current is not None and (expected is None or digest(current) != expected))
                or (current is None and expected is not None)):
            conflicts.append(name)
        changes[name] = (data, mode, current)
    if conflicts and not replace_local:
        raise ValueError("Local deployment changes detected; no files changed:\n  " + "\n  ".join(conflicts)
                         + "\nReview them, or explicitly use --replace-local-deploy-files to back up and replace them.")
    if not changes:
        print(f"Deployment files already match {ref} ({commit}).")
        return None
    history = root / HISTORY
    if history.is_symlink():
        raise ValueError("Deployment backup directory must not be a symbolic link")
    history.mkdir(mode=0o700, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-"), dir=history))
    metadata = {"previous_state": old_state, "files": {}}
    for name, (data, mode, current) in changes.items():
        target = safe_path(root, name)
        item = {"existed": current is not None, "installed_sha256": digest(data)}
        if current is not None:
            item.update(mode=stat.S_IMODE(target.stat().st_mode), original_sha256=digest(current))
            atomic_write(backup / "files" / name, current)
        metadata["files"][name] = item
    atomic_write(backup / "manifest.json", json.dumps(metadata, indent=2).encode())
    written = []
    try:
        for name, (data, mode, current) in changes.items():
            atomic_write(safe_path(root, name), data, mode)
            written.append(name)
        state = {"ref": ref, "commit": commit, "files": {name: digest(data) for name, (data, _) in files.items()}, "backup": str(backup.relative_to(root))}
        atomic_write(root / STATE, json.dumps(state, indent=2).encode())
    except BaseException:
        for name in reversed(written):
            data, mode, current = changes[name]
            target = safe_path(root, name)
            if current is None:
                target.unlink(missing_ok=True)
            else:
                atomic_write(target, current, metadata["files"][name]["mode"])
        raise
    print(f"Deployment files updated to {ref} ({commit}). Backup: {backup}")
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--ref")
    action.add_argument("--restore", type=Path, help="Restore the printed deployment-files backup; leaves .env and data unchanged")
    parser.add_argument("--replace-local-deploy-files", action="store_true")
    args = parser.parse_args()
    root = args.directory.resolve()
    try:
        if not (root / ".env").is_file():
            raise ValueError("No installed deployment (.env missing)")
        if (root / ".deploy-refresh.lock").is_symlink():
            raise ValueError("Invalid refresh lock")
        # Atomic directory creation prevents concurrent refreshes on Linux and Windows.
        lock = root / ".deploy-refresh.lock"
        lock.mkdir(mode=0o700)
        try:
            if args.restore:
                restore(root, args.restore if args.restore.is_absolute() else root / args.restore)
                print("Deployment files restored. Run ./update.sh --rollback to restore the application images and apply Compose.")
            else:
                state = load_state(root)
                baseline = state["files"] if state else {}
                if not state and not args.replace_local_deploy_files:
                    version = (root / "VERSION").read_text(encoding="utf-8").strip()
                    _, original = fetch_release("v" + version.lstrip("v"))
                    baseline = {name: digest(data) for name, (data, _) in original.items()}
                commit, files = fetch_release(args.ref)
                apply_release(root, args.ref, commit, files, baseline, args.replace_local_deploy_files)
        finally:
            lock.rmdir()
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        parser.exit(1, f"Deploy refresh aborted: {error}\n")


if __name__ == "__main__":
    main()
