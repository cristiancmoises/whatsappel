#!/usr/bin/env fish
# SPDX-License-Identifier: AGPL-3.0-only
# Build an isolated publication checkout, audit, commit curated paths, and push all four forges.
# Tokens are entered through hidden prompts, never inserted into Git URLs or stored in files.
function whatsappel_commit_and_push
    for program in python3 git realpath
        type -q $program; or begin
            echo "Stopped: $program is required." >&2
            return 1
        end
    end
    set -l script_dir (dirname (status --current-filename))
    set -l bundle (realpath "$script_dir/..")
    or return 1
    python3 "$bundle/scripts/commit-update.py" --bundle "$bundle" $argv
end
whatsappel_commit_and_push $argv
