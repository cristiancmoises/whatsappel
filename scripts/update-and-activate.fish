#!/usr/bin/env fish
# SPDX-License-Identifier: AGPL-3.0-only
# No service restart unless --restart-local is explicitly selected.
function whatsappel_update_and_activate
    for program in python3 realpath
        if not type -q "$program"
            printf 'Stopped: required program is missing: %s\n' "$program" >&2
            return 1
        end
    end
    set -l scripts (dirname (status --current-filename))
    set -l bundle (realpath "$scripts/..")
    or return 1
    python3 "$bundle/scripts/finish-update.py" --bundle "$bundle" $argv
end
whatsappel_update_and_activate $argv
