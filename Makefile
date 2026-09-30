# whatsappel — reproducible local checks and convenience targets
SHELL := /bin/bash
CARGO ?= cargo
BIN ?= $(HOME)/.local/bin

.PHONY: help setup check check-client check-bridge check-python check-rust pqenv install run clean audit audit-advisories
help:
	@echo 'make check   - client, bridge, publishing and Rust regression tests'
	@echo 'make audit   - run every local audit gate, record failures and missing tools'
	@echo 'make audit-advisories - check Cargo.lock against an updated RustSec database'
	@echo 'make setup | pqenv | install | run | clean'

setup:
	./setup.sh

check: check-client check-bridge check-python check-rust

check-client:
	emacs -Q --batch -L . -f batch-byte-compile whatsapp.el whatsapp-org.el whatsapp-profiles.el whatsapp-delivery.el whatsapp-tools.el
	emacs -Q --batch -L . -L tests -l tests/client-tests.el -l tests/whatsapp-org-tests.el -l tests/workspace-tests.el -l tests/performance-tests.el -l tests/responsiveness-tests.el -l tests/navigation-tests.el -l tests/selection-tests.el -l tests/profiles-tests.el -l tests/delivery-tests.el -l tests/recipient-ui-tests.el -l tests/repair-tests.el -l tests/media-profile-repair-tests.el -l tests/session-recovery-tests.el -l tests/reliability-tests.el -l tests/tools-tests.el -f ert-run-tests-batch-and-exit

check-bridge:
	guile --no-auto-compile tests/bridge-tests.scm

check-python:
	@results=$$(mktemp -d "$${TMPDIR:-/tmp}/whatsappel-python.XXXXXX"); \
	printf 'Test evidence: %s\n' "$$results"; \
	python3 -I scripts/run-tests.py --report "$$results/results.json"
	@for script in scripts/*.fish; do fish --no-execute "$$script" || exit; done

check-rust:
	$(CARGO) test --locked --manifest-path pqenv/Cargo.toml

pqenv:
	$(CARGO) build --locked --release --manifest-path pqenv/Cargo.toml

install: pqenv
	install -d "$(BIN)"
	install -m 0755 pqenv/target/release/pqenv "$(BIN)/pqenv"

run:
	set -a; . ./.env; set +a; guile whatsappel.scm

clean:
	rm -f whatsapp.elc whatsapp-org.elc whatsappel.go
	$(CARGO) clean --manifest-path pqenv/Cargo.toml

audit:
	python3 -I scripts/audit-workspace.py . --scope full

audit-advisories:
	cd pqenv && $(CARGO) audit

check-read-api:
	@results=$$(mktemp -d "$${TMPDIR:-/tmp}/whatsappel-read-api.XXXXXX"); \
	printf 'Test evidence: %s\n' "$$results"; \
	python3 -I scripts/run-tests.py --pattern test_read_api_http.py --report "$$results/results.json"

benchmark-client:
	emacs -Q --batch -L . -l tests/benchmark-client.el

check-responsiveness:
	@results=$$(mktemp -d "$${TMPDIR:-/tmp}/whatsappel-responsiveness.XXXXXX"); \
	printf 'Test evidence: %s\n' "$$results"; \
	python3 -I scripts/run-tests.py --pattern test_read_worker.py --report "$$results/results.json"


benchmark-profiles:
	emacs -Q --batch -L . -l tests/benchmark-profiles.el
