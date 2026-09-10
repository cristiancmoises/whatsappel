#!/usr/bin/env fish
# SPDX-License-Identifier: AGPL-3.0-only
# IONOS: root@securityops.co, SSH port 5119. Host-key verification stays enabled.
function whatsappel_deploy_ionos
    for program in python3 ssh scp realpath
        type -q $program; or begin
            echo "Stopped: $program is required." >&2
            return 1
        end
    end
    set -l script_dir (dirname (status --current-filename))
    set -l bundle (realpath "$script_dir/..")
    or return 1
    python3 "$bundle/scripts/deploy-ionos.py" --bundle "$bundle" $argv
end
whatsappel_deploy_ionos $argv
