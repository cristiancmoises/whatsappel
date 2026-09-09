#!/usr/bin/env fish
# Tokens are requested by Python through /dev/tty; never put them in arguments.
set -l script_dir (path dirname (status filename))
if not command -q python3
    printf '%s\n' 'Python 3 is required (on Guix: guix shell python git fish).'
    exit 1
end
python3 "$script_dir/publish.py" $argv
exit $status
