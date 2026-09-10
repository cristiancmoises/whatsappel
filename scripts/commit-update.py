#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Commit only this delta in an isolated publication checkout, then publish with hidden tokens."""
from __future__ import annotations
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys


def git(repo, *args, check=True, isolated=False, identity=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in {"SSH_ASKPASS", "CURL_VERBOSE", "SSLKEYLOGFILE"}}
    env["GIT_TERMINAL_PROMPT"] = "0"
    if isolated:
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    command = ["git", "-C", str(repo), "-c", "core.hooksPath=" + os.devnull]
    if identity:
        command += ["-c", "user.name=" + identity[0], "-c", "user.email=" + identity[1]]
    result = subprocess.run(command + list(args), env=env, capture_output=True, text=True, timeout=180)
    if check and result.returncode:
        raise ValueError("Git step failed: " + args[0] + "; no force push/reset was used. Inspect the publication checkout.")
    return result


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("repository", nargs="?", type=Path, default=Path.home() / "whatsappel")
    p.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--worktree", type=Path, default=Path.home() / "whatsappel-publish-3.2.0-rc1")
    p.add_argument("--branch", default="main", help="Destination branch, never force-pushed")
    p.add_argument("--create-missing", action="store_true")
    p.add_argument("--visibility", choices=("public", "private"))
    p.add_argument("--commit-only", action="store_true")
    p.add_argument("--remote", action="append", choices=("forgejo-co", "forgejo-com-br", "github", "codeberg"))
    a = p.parse_args(argv)
    bundle, source, work = a.bundle.expanduser().absolute(), a.repository.expanduser().absolute(), a.worktree.expanduser().absolute()
    ms = importlib.util.spec_from_file_location("whatsappel_installer", bundle / "scripts/update-package.py")
    installer = importlib.util.module_from_spec(ms)
    ms.loader.exec_module(installer)
    spec = installer.verify_bundle(bundle)
    if a.create_missing and not a.visibility:
        raise ValueError("--create-missing requires --visibility public or private")
    if work == source:
        raise ValueError("Choose a separate publication worktree; the existing installation is not committed in place")
    installer.no_links(work)
    source_git = source.is_dir() and git(source, "rev-parse", "--is-inside-work-tree", check=False).returncode == 0
    config_root = source if source_git else Path.home()
    name = git(config_root, "config", "--get", "user.name", check=False).stdout.strip()
    email = git(config_root, "config", "--get", "user.email", check=False).stdout.strip()
    if not name or not email:
        raise ValueError("Configure your real Git user.name and user.email before committing; identity is never invented")
    if not work.exists():
        if source_git:
            git(source, "worktree", "add", "-b", "whatsappel-3.2.0-rc1", str(work), "HEAD")
            print("Publication starts from committed HEAD. Uncommitted changes in your original checkout are not included or modified.", flush=True)
        else:
            print("Installation is not a Git checkout. Creating a separate public Codeberg clone; original installation is unchanged.", flush=True)
            git(work.parent, "-c", "credential.helper=", "-c", "http.followRedirects=false", "clone", "--", "https://codeberg.org/berkeley/whatsappel.git", str(work), isolated=True)
            git(work, "switch", "-c", "whatsappel-3.2.0-rc1")
    if git(work, "rev-parse", "--show-toplevel").stdout.strip() != str(work):
        raise ValueError("Publication path must be the exact repository root")
    if git(work, "symbolic-ref", "--short", "HEAD").stdout.strip() != "whatsappel-3.2.0-rc1":
        raise ValueError("Publication worktree is on a different branch; no changes made")
    allowed = {item["path"] for item in spec["files"]}
    changed = set(git(work, "diff", "HEAD", "--name-only", "-z").stdout.split("\0")) - {""}
    untracked = set(git(work, "ls-files", "--others", "--exclude-standard", "-z").stdout.split("\0")) - {""}
    if (changed | untracked) - allowed:
        raise ValueError("Publication checkout has unrelated changes; preserve/reconcile them before retrying")
    # Native tests run before installation into even this isolated publication worktree.
    installer.main([str(work), "--bundle", str(bundle), "--apply"])
    for item in spec["files"]:
        if installer.digest(work / item["path"]) != item["after"]:
            raise ValueError("Managed source changed during preparation; nothing committed")
    git(work, "add", "--", *sorted(allowed))
    staged = set(git(work, "diff", "--cached", "--name-only", "-z").stdout.split("\0")) - {""}
    if staged - allowed:
        raise ValueError("Unexpected staged paths; nothing committed")
    if staged:
        git(work, "commit", "-m", "Improve WhatsAppel workspace, media preview and asynchronous uploads", "-m", "Prepare 3.2.0-rc1 with bounded history, explicit attachment preview/send, mpv playback, and guarded update workflows. Live graphical and WhatsApp validation remains a release gate.", identity=(name, email))
    commit = git(work, "rev-parse", "HEAD").stdout.strip()
    print("Publication checkout: " + str(work) + "\nCommit: " + commit, flush=True)
    if a.commit_only:
        return 0
    command = [sys.executable, str(bundle / "scripts/publish.py"), str(work), "--branch", a.branch]
    for remote in a.remote or ("forgejo-co", "forgejo-com-br", "github", "codeberg"):
        command += ["--remote", remote]
    if a.create_missing:
        command.append("--create-missing")
    if a.visibility:
        command += ["--visibility", a.visibility]
    return subprocess.call(command)

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("Stopped: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
