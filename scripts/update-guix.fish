#!/usr/bin/env fish
# SPDX-License-Identifier: AGPL-3.0-only
# Default: update existing source after two full audits. No root or Guix profile change.
function whatsappel_update_guix
    for program in python3 realpath
        type -q $program; or begin
            printf 'Stopped: required program is missing: %s\n' "$program" >&2
            return 1
        end
    end
    set -l script_dir (dirname (status --current-filename))
    set -l bundle (realpath "$script_dir/..")
    or return 1
    python3 "$bundle/scripts/guix-workflow.py" --bundle "$bundle" $argv
end
whatsappel_update_guix $argv
