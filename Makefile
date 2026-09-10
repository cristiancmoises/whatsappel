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
	emacs -Q --batch -L . -f batch-byte-compile whatsapp.el whatsapp-org.el
	emacs -Q --batch -L . -l tests/client-tests.el -l tests/whatsapp-org-tests.el -l tests/workspace-tests.el -f ert-run-tests-batch-and-exit

check-bridge:
	guile --no-auto-compile tests/bridge-tests.scm

check-python:
	python3 -m unittest discover -s tests -p 'test_*.py' -v
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
	audit/security-audit.sh

audit-advisories:
	cd pqenv && $(CARGO) audit
