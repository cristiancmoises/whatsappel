#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Run independent checks through failure; never turn absent tools into passes.
set -uo pipefail
umask 077
cd "$(dirname "$0")/.." || exit 1
report_dir="${WHATSAPPEL_AUDIT_DIR:-audit/results}"
mkdir -p "$report_dir" || exit 1
summary="$report_dir/summary.tsv"
printf 'check\tstatus\texit_code\n' > "$summary"
failed=0
run() {
    local name="$1" tool="$2"; shift 2
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '%s\tBLOCKED\t127\n' "$name" >> "$summary"
        printf 'BLOCKED %s: missing %s\n' "$name" "$tool"
        failed=1; return
    fi
    "$@" > "$report_dir/$name.log" 2>&1
    local code=$?
    if [ "$code" -eq 0 ]; then
        printf '%s\tPASS\t0\n' "$name" >> "$summary"
        printf 'PASS %s\n' "$name"
    else
        printf '%s\tFAIL\t%s\n' "$name" "$code" >> "$summary"
        printf 'FAIL %s (exit %s; %s/%s.log)\n' "$name" "$code" "$report_dir" "$name"
        failed=1
    fi
}
run source-whitespace git git diff --check
run shell-syntax bash bash -n setup.sh audit/security-audit.sh
run client emacs make check-client
run bridge guile make check-bridge
run publishing python3 make check-python
run rust-tests cargo cargo test --locked --manifest-path pqenv/Cargo.toml
run rust-format cargo cargo fmt --manifest-path pqenv/Cargo.toml -- --check
run rust-clippy cargo cargo clippy --locked --manifest-path pqenv/Cargo.toml --all-targets -- -D warnings
# This is a separate network-dependent gate, never implied by the local result.
if [ "${WHATSAPPEL_AUDIT_ADVISORIES:-0}" = 1 ]; then
    run rustsec cargo-audit make audit-advisories
else
    printf 'rustsec\tNOT_RUN\t-\n' >> "$summary"
fi
printf 'Results: %s\nLive WhatsApp, graphical rendering and upstream wuzapi deployment require separate validation.\n' "$summary"
exit "$failed"
