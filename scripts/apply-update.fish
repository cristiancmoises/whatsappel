#!/usr/bin/env fish
# Apply into a new branch/worktree, preserving work in the original checkout.
set -l script_dir (path dirname (status filename))
if not command -q python3
    printf '%s\n' 'Python 3 is required (on Guix: guix shell python git fish).'
    exit 1
end
python3 "$script_dir/apply-update.py" $argv
exit $status
