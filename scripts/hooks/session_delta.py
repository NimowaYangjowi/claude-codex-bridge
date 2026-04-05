#!/usr/bin/env python3

import argparse
import difflib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


STATE_ROOT = Path("/tmp/codex-session-state")
TRACK_FILE_TEMPLATE = "/tmp/claude-modified-files-{session_id}.txt"


def sanitize_session_id(raw: str | None) -> str:
    if not raw:
        return ""
    filtered = "".join(ch for ch in raw if ch.isalnum() or ch in {"_", "-"})
    return filtered[:64]


def load_stdin_json() -> dict:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def git(repo_root: Path, args: list[str], *, env: dict | None = None, check: bool = True, input_bytes: bytes | None = None) -> subprocess.CompletedProcess:
    cmd = ["git", *args]
    result = subprocess.run(
        cmd,
        cwd=repo_root,
        env=env,
        input=input_bytes,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip() or "git command failed")
    return result


def resolve_repo_root(payload: dict) -> Path | None:
    cwd = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=cwd,
            capture_output=True,
            check=False,
            text=True,
        )
    except Exception:
        return None

    if result.returncode != 0:
        return None
    return Path(result.stdout.strip())


def current_changed_paths(repo_root: Path) -> list[str]:
    paths: set[str] = set()
    commands = [
        ["diff", "--name-only", "-z"],
        ["diff", "--cached", "--name-only", "-z"],
        ["ls-files", "--others", "--exclude-standard", "-z"],
    ]
    for cmd in commands:
        result = git(repo_root, cmd, check=False)
        raw = result.stdout.decode("utf-8", errors="surrogateescape")
        for path in raw.split("\0"):
            if path:
                paths.add(path)
    return sorted(paths)


def path_in_head(repo_root: Path, path: str) -> bool:
    result = git(repo_root, ["cat-file", "-e", f"HEAD:{path}"], check=False)
    return result.returncode == 0


def head_bytes(repo_root: Path, path: str) -> bytes | None:
    result = git(repo_root, ["show", f"HEAD:{path}"], check=False)
    if result.returncode != 0:
        return None
    return result.stdout


def file_bytes(path: Path) -> bytes | None:
    if not path.exists():
        return None
    return path.read_bytes()


def is_binary_blob(blob: bytes | None) -> bool:
    return blob is not None and b"\0" in blob


def state_dir(session_id: str) -> Path:
    return STATE_ROOT / session_id


def metadata_path(session_id: str) -> Path:
    return state_dir(session_id) / "baseline.json"


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def capture_baseline(repo_root: Path, session_id: str) -> dict:
    changed_paths = current_changed_paths(repo_root)
    target_dir = state_dir(session_id)
    snapshots_dir = target_dir / "snapshots"
    shutil.rmtree(target_dir, ignore_errors=True)
    snapshots_dir.mkdir(parents=True, exist_ok=True)

    baseline = {
        "repo_root": str(repo_root),
        "head": git(repo_root, ["rev-parse", "HEAD"], check=False).stdout.decode().strip() or None,
        "paths": {},
    }

    for rel_path in changed_paths:
        repo_file = repo_root / rel_path
        snapshot_rel = Path("snapshots") / rel_path
        snapshot_abs = target_dir / snapshot_rel
        exists = repo_file.exists()

        if exists:
            ensure_parent(snapshot_abs)
            shutil.copyfile(repo_file, snapshot_abs)

        baseline["paths"][rel_path] = {
            "snapshot": str(snapshot_rel),
            "exists": exists,
            "tracked_at_head": path_in_head(repo_root, rel_path),
        }

    metadata_path(session_id).write_text(json.dumps(baseline, ensure_ascii=False, indent=2))
    return {"path_count": len(changed_paths)}


def load_baseline(repo_root: Path, session_id: str) -> dict | None:
    meta_path = metadata_path(session_id)
    if not meta_path.exists():
        return None
    data = json.loads(meta_path.read_text())
    if data.get("repo_root") != str(repo_root):
        return None
    return data


def write_temp_bytes(temp_dir: Path, rel_path: str, data: bytes | None) -> Path:
    target = temp_dir / rel_path
    if data is None:
        return target
    ensure_parent(target)
    target.write_bytes(data)
    return target


def stage_path_in_temp_index(repo_root: Path, temp_index: Path, rel_path: str) -> None:
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = str(temp_index)
    repo_file = repo_root / rel_path
    if repo_file.exists():
        git(repo_root, ["add", "--", rel_path], env=env)
    else:
        git(repo_root, ["add", "-u", "--", rel_path], env=env)


def apply_patch_to_temp_index(repo_root: Path, temp_index: Path, patch: bytes) -> None:
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = str(temp_index)
    result = git(
        repo_root,
        ["apply", "--cached", "--whitespace=nowarn", "--binary", "-"],
        env=env,
        check=False,
        input_bytes=patch,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip() or "failed to apply patch to temp index")


def diff_between(_repo_root: Path, rel_path: str, old_path: Path, new_path: Path) -> bytes:
    old_text = old_path.read_text(errors="surrogateescape").splitlines(keepends=True) if old_path.exists() else []
    new_text = new_path.read_text(errors="surrogateescape").splitlines(keepends=True) if new_path.exists() else []
    patch = "".join(
        difflib.unified_diff(
            old_text,
            new_text,
            fromfile=f"a/{rel_path}",
            tofile=f"b/{rel_path}",
        )
    )
    return patch.encode("utf-8", errors="surrogateescape")


def merge_session_delta(head_blob: bytes | None, baseline_blob: bytes | None, current_blob: bytes | None, rel_path: str) -> tuple[bytes | None, str | None]:
    if current_blob == baseline_blob:
        return head_blob, None

    if current_blob is None:
        return None, None

    if baseline_blob is None:
        return None, f"`{rel_path}` was already an untracked file before this session, so Codex cannot safely isolate only this session's additions."

    if head_blob is None:
        return None, f"`{rel_path}` did not exist in HEAD and was already dirty before this session, so Codex cannot safely isolate only this session's additions."

    if is_binary_blob(head_blob) or is_binary_blob(baseline_blob) or is_binary_blob(current_blob):
        return None, f"`{rel_path}` looks binary and was already dirty before this session, so Codex cannot safely isolate this session's changes."

    with tempfile.TemporaryDirectory(prefix="codex-merge-") as tmp:
        tmpdir = Path(tmp)
        head_path = write_temp_bytes(tmpdir / "head", rel_path, head_blob)
        baseline_path = write_temp_bytes(tmpdir / "baseline", rel_path, baseline_blob)
        current_path = write_temp_bytes(tmpdir / "current", rel_path, current_blob)
        result = subprocess.run(
            ["git", "merge-file", "-p", str(head_path), str(baseline_path), str(current_path)],
            capture_output=True,
            check=False,
        )
        if result.returncode not in (0, 1):
            return None, f"Failed to isolate the session-only changes for `{rel_path}`."
        merged = result.stdout
        if result.returncode == 1 and b"<<<<<<<" in merged:
            return None, f"`{rel_path}` already had local edits before this session, and this session touched overlapping lines. Codex cannot auto-commit only the new session delta safely."
        return merged, None


def build_temp_index(repo_root: Path) -> tuple[Path, str | None]:
    temp_index = Path(tempfile.mkstemp(prefix="codex-temp-index-")[1])
    head = git(repo_root, ["rev-parse", "HEAD"], check=False).stdout.decode().strip() or None
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = str(temp_index)
    if head:
        git(repo_root, ["read-tree", "HEAD"], env=env)
    return temp_index, head


def commit_from_temp_index(repo_root: Path, temp_index: Path, old_head: str | None, commit_message: str, committed_paths: list[str]) -> str | None:
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = str(temp_index)
    diff_cmd = ["diff", "--cached", "--quiet"]
    if old_head:
        diff_result = git(repo_root, diff_cmd, env=env, check=False)
        if diff_result.returncode == 0:
            return None
    else:
        listed = git(repo_root, ["ls-files", "--cached"], env=env, check=False).stdout.strip()
        if not listed:
            return None

    tree = git(repo_root, ["write-tree"], env=env).stdout.decode().strip()
    commit_args = ["commit-tree", tree, "-m", commit_message]
    if old_head:
        commit_args[2:2] = ["-p", old_head]
    new_commit = git(repo_root, commit_args).stdout.decode().strip()

    symbolic_ref = git(repo_root, ["symbolic-ref", "-q", "HEAD"], check=False).stdout.decode().strip()
    if symbolic_ref:
        update_args = ["update-ref", symbolic_ref, new_commit]
        if old_head:
            update_args.append(old_head)
        git(repo_root, update_args)
    else:
        update_args = ["update-ref", "HEAD", new_commit]
        if old_head:
            update_args.append(old_head)
        git(repo_root, update_args)

    if committed_paths:
        git(repo_root, ["reset", "-q", "HEAD", "--", *committed_paths], check=False)
    return new_commit


def tracked_file_fallback(repo_root: Path, session_id: str, temp_index: Path) -> list[str]:
    track_path = Path(TRACK_FILE_TEMPLATE.format(session_id=session_id))
    if not track_path.exists():
        return []
    staged: list[str] = []
    for raw in sorted(set(track_path.read_text().splitlines())):
        if not raw.strip():
            continue
        try:
            rel_path = str(Path(raw).resolve().relative_to(repo_root.resolve()))
        except Exception:
            rel_path = raw
        if rel_path.startswith(".."):
            continue
        stage_path_in_temp_index(repo_root, temp_index, rel_path)
        staged.append(rel_path)
    return staged


def commit_session_delta(repo_root: Path, session_id: str) -> dict:
    baseline = load_baseline(repo_root, session_id)
    temp_index, old_head = build_temp_index(repo_root)
    staged_paths: list[str] = []
    blockers: list[str] = []

    try:
        if baseline:
            current_changed = set(current_changed_paths(repo_root))
            baseline_paths = baseline.get("paths", {})
            candidates = sorted(current_changed | set(baseline_paths.keys()))

            for rel_path in candidates:
                if rel_path in baseline_paths:
                    meta = baseline_paths[rel_path]
                    baseline_blob = None
                    snapshot_rel = meta.get("snapshot")
                    if meta.get("exists") and snapshot_rel:
                        baseline_blob = file_bytes(state_dir(session_id) / snapshot_rel)

                    head_blob = head_bytes(repo_root, rel_path) if meta.get("tracked_at_head") else None
                    current_blob = file_bytes(repo_root / rel_path)

                    if current_blob == baseline_blob:
                        continue

                    if current_blob is None:
                        if head_blob is None:
                            blockers.append(f"`{rel_path}` was already untracked before this session and is now deleted, so Codex cannot isolate a session-only commit safely.")
                            continue
                        stage_path_in_temp_index(repo_root, temp_index, rel_path)
                        staged_paths.append(rel_path)
                        continue

                    merged_blob, error = merge_session_delta(head_blob, baseline_blob, current_blob, rel_path)
                    if error:
                        blockers.append(error)
                        continue
                    if merged_blob == head_blob:
                        continue

                    with tempfile.TemporaryDirectory(prefix="codex-stage-") as tmp:
                        tmpdir = Path(tmp)
                        old_temp = write_temp_bytes(tmpdir / "old", rel_path, head_blob)
                        new_temp = write_temp_bytes(tmpdir / "new", rel_path, merged_blob)
                        patch = diff_between(repo_root, rel_path, old_temp, new_temp)
                        if patch:
                            apply_patch_to_temp_index(repo_root, temp_index, patch)
                            staged_paths.append(rel_path)
                else:
                    stage_path_in_temp_index(repo_root, temp_index, rel_path)
                    staged_paths.append(rel_path)
        else:
            staged_paths = tracked_file_fallback(repo_root, session_id, temp_index)

        if blockers:
            return {"ok": False, "reason": "\n".join(blockers[:10])}

        staged_paths = sorted(set(staged_paths))
        if len(staged_paths) == 1:
            message = f"refactor: update {Path(staged_paths[0]).name} via session hooks"
        else:
            message = f"refactor: update {len(staged_paths)} files via session hooks"

        new_commit = commit_from_temp_index(repo_root, temp_index, old_head, message, staged_paths)
        return {"ok": True, "commit": new_commit, "paths": staged_paths}
    finally:
        temp_index.unlink(missing_ok=True)


def cleanup_state(session_id: str) -> None:
    shutil.rmtree(state_dir(session_id), ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["capture-baseline", "commit-session-delta", "stop-hook", "cleanup"])
    args = parser.parse_args()

    payload = load_stdin_json()
    session_id = sanitize_session_id(
        payload.get("session_id")
        or os.environ.get("CLAUDE_SESSION_ID")
        or os.environ.get("CODEX_THREAD_ID")
    )

    repo_root = resolve_repo_root(payload)
    if not session_id or repo_root is None:
        if args.command == "stop-hook":
            print(json.dumps({"continue": True}))
        return 0

    if args.command == "capture-baseline":
        capture_baseline(repo_root, session_id)
        return 0

    if args.command == "commit-session-delta":
        result = commit_session_delta(repo_root, session_id)
        if not result["ok"]:
            print(result["reason"], file=sys.stderr)
            return 2
        commit = result.get("commit")
        if commit:
            print(f"Committed session-only changes in {len(result.get('paths', []))} file(s).")
        return 0

    if args.command == "cleanup":
        cleanup_state(session_id)
        return 0

    stop_hook_active = payload.get("stop_hook_active")
    if stop_hook_active in (True, "true", "True"):
        print(json.dumps({"continue": True}))
        return 0

    result = commit_session_delta(repo_root, session_id)
    if not result["ok"]:
        print(json.dumps({"decision": "block", "reason": result["reason"]}, ensure_ascii=False))
        return 0

    cleanup_state(session_id)
    message = None
    if result.get("commit"):
        message = f"Codex native hooks committed this session's changes in {len(result.get('paths', []))} file(s)."
    print(json.dumps({"continue": True, "systemMessage": message}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
