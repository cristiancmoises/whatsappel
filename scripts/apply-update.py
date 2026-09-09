#!/usr/bin/env python3
"""Apply an audited patch on top of current HEAD in a separate Git worktree.

Modified/staged/untracked files in the user's active checkout are preserved.
The new worktree starts at the user's current commit, never the old baseline.
Conflicts are retained exclusively in the new worktree for explicit resolution.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


class ApplyError(Exception):
    pass


def run(repo, *args, check=True):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.pop("SSH_ASKPASS", None)
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "-c", "core.hooksPath=" + os.devnull, *args],
            text=True, capture_output=True, encoding="utf-8", errors="replace", env=env, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ApplyError("Git could not finish; verify Git is installed and inspect the indicated worktree.") from exc
    if check and result.returncode:
        raise ApplyError(result.stderr.strip() or "Git command failed.")
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path, help="Your existing WhatsAppel Git checkout (may have ongoing changes)")
    parser.add_argument("patch", type=Path, help="Full-index binary upgrade.patch from this delivery")
    parser.add_argument("baseline", help="Baseline commit SHA or path to BASELINE_COMMIT")
    parser.add_argument("--worktree", type=Path, help="New, nonexistent worktree directory (default: beside repository)")
    parser.add_argument("--branch", help="New local branch name (default: whatsappel-upgrade/<UTC timestamp>)")
    parser.add_argument("--sha256", help="Expected SHA-256 of upgrade.patch")
    parser.add_argument("--commit", action="store_true", help="Commit successful application with your configured Git identity")
    return parser.parse_args(argv)


def fish_quote(value):
    """Quote a literal argument for fish without executing shell substitution."""
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def main(argv=None):
    args = parse_args(argv)
    worktree = None
    created = False
    try:
        repo = args.repository.expanduser().resolve()
        patch = args.patch.expanduser().resolve()
        baseline_path = Path(args.baseline).expanduser()
        baseline = baseline_path.read_text(encoding="ascii").strip() if baseline_path.is_file() else args.baseline
        if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", baseline):
            raise ApplyError("Baseline must be a complete commit SHA or a BASELINE_COMMIT file containing one.")
        if not patch.is_file() or patch.stat().st_size == 0:
            raise ApplyError("Patch does not exist or is empty.")
        digest = hashlib.sha256(patch.read_bytes()).hexdigest()
        if args.sha256 and digest != args.sha256.lower():
            raise ApplyError("Patch SHA-256 does not match; no worktree created.")
        if run(repo, "rev-parse", "--is-inside-work-tree").stdout.strip() != "true":
            raise ApplyError("Choose an existing Git worktree.")
        repo = Path(run(repo, "rev-parse", "--show-toplevel").stdout.strip())
        head = run(repo, "rev-parse", "HEAD").stdout.strip()
        original_branch = run(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False).stdout.strip()
        if run(repo, "cat-file", "-e", baseline + "^{commit}", check=False).returncode:
            raise ApplyError("Baseline commit is absent. Fetch repository history (deepen a shallow clone if needed), then retry.")
        if run(repo, "merge-base", "--is-ancestor", baseline, head, check=False).returncode:
            raise ApplyError("Baseline is not an ancestor of current HEAD. Choose the matching project history; no changes made.")
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        branch = args.branch or "whatsappel-upgrade/" + timestamp
        if run(repo, "check-ref-format", "--branch", branch, check=False).returncode:
            raise ApplyError("Invalid branch name.")
        worktree = (args.worktree.expanduser().resolve() if args.worktree else repo.parent / (repo.name + "-upgrade-" + timestamp))
        if worktree.exists() or worktree.is_symlink():
            raise ApplyError("Destination already exists; choose a new --worktree path.")
        if not run(repo, "show-ref", "--verify", "--quiet", "refs/heads/" + branch, check=False).returncode:
            raise ApplyError("Upgrade branch already exists; choose a new --branch name.")
        if args.commit and run(repo, "var", "GIT_AUTHOR_IDENT", check=False).returncode:
            raise ApplyError("Configure your Git user.name and user.email before using --commit.")
        print(f"Original checkout: {repo}\nStarting commit: {head}\nPatch SHA-256: {digest}", flush=True)
        run(repo, "worktree", "add", "-b", branch, str(worktree), head)
        created = True
        print(f"Upgrade worktree: {worktree}\nUpgrade branch: {branch}", flush=True)
        result = run(worktree, "apply", "--3way", "--index", "--whitespace=error-all", str(patch), check=False)
        if result.returncode:
            print(result.stderr.strip(), file=sys.stderr)
            print(f"Application stopped. Your original checkout is untouched.\nInspect/resolve only in: {worktree}\nThe new branch/worktree is retained; nothing was published.", file=sys.stderr)
            return 2
        if not run(worktree, "diff", "--cached", "--quiet", check=False).returncode:
            print("Patch is already present; the new worktree has no changes.")
        elif args.commit:
            run(worktree, "commit", "-m", "Improve WhatsAppel navigation, attachments, and media handling")
            print("Committed upgrade: " + run(worktree, "rev-parse", "HEAD").stdout.strip())
        else:
            print("Applied and staged. Review the changes and commit before publication.")
        print(f"\nReady for review: {worktree}\nThe original checkout's index and files were preserved.")
        publisher = Path(__file__).resolve().with_name("publish.fish")
        if original_branch:
            print("\nCheck publication (fish):\nfish " + fish_quote(publisher) + " " + fish_quote(worktree)
                  + " --branch " + fish_quote(original_branch) + " --dry-run")
            print("Publish to all four forges, creating missing public repositories (fish):\nfish "
                  + fish_quote(publisher) + " " + fish_quote(worktree) + " --branch "
                  + fish_quote(original_branch) + " --create-missing --visibility public")
            print("Use --visibility private instead if the destinations should be private.")
        else:
            print("Original checkout had detached HEAD; select an explicit --branch for publish.fish.")
        return 0
    except (ApplyError, OSError, UnicodeError) as exc:
        print(f"Stopped: {exc}", file=sys.stderr)
        if created:
            print(f"Upgrade worktree retained for inspection: {worktree}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted. Inspect any newly created upgrade worktree before retrying.", file=sys.stderr)
        raise SystemExit(130)
