#!/usr/bin/env fish
# SPDX-License-Identifier: AGPL-3.0-only
# Run only after the guarded commit command succeeded. This never stages/commits files.
function whatsappel_push_four
    for program in python3 realpath
        type -q $program; or begin
            printf 'Stopped: required program is missing: %s\n' "$program" >&2
            return 1
        end
    end
    set -l script_dir (dirname (status --current-filename))
    set -l bundle (realpath "$script_dir/..")
    or return 1
    set -l worktree "$HOME/whatsappel-publish-3.3.0"
    if test (count $argv) -gt 0; and not string match -q -- '-*' "$argv[1]"
        set worktree "$argv[1]"
        set -e argv[1]
    end
    python3 "$bundle/scripts/publish.py" "$worktree" --branch main $argv
end
whatsappel_push_four $argv
