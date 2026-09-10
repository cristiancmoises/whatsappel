#!/usr/bin/env fish
# SPDX-License-Identifier: AGPL-3.0-only
# Run from the extracted update package. No Bash heredocs or shell-evaluated secrets.
function whatsappel_install_local
    type -q python3; or begin
        echo 'Stopped: Python 3 is required.' >&2
        return 1
    end
    set -l script_dir (dirname (status --current-filename))
    set -l bundle (realpath "$script_dir/..")
    or return 1
    if test (count $argv) -eq 0
        set argv "$HOME/whatsappel"
    end
    python3 "$bundle/scripts/update-package.py" --bundle "$bundle" --apply --desktop $argv
end
whatsappel_install_local $argv
