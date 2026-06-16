# whatsappel — convenience targets
SHELL := /bin/bash
CARGO ?= cargo
BIN   ?= $(HOME)/.local/bin

.PHONY: help setup check pqenv install run clean

help:
	@echo "make setup   - build pqenv, install, create config + token"
	@echo "make check   - compile bridge, byte-compile client, build pqenv, run tests"
	@echo "make pqenv   - build pqenv (release)"
	@echo "make install - install pqenv to $(BIN)"
	@echo "make run     - load .env and start the Guile bridge"
	@echo "make clean   - remove build artifacts"

setup:
	./setup.sh

check:
	guile -c '(use-modules (system base compile)) (compile-file "whatsappel.scm" #:output-file "/tmp/whatsappel.go")'
	emacs -Q --batch -L . -f batch-byte-compile whatsapp.el
	$(CARGO) build --release --manifest-path pqenv/Cargo.toml
	$(CARGO) test --manifest-path pqenv/Cargo.toml

pqenv:
	$(CARGO) build --release --manifest-path pqenv/Cargo.toml

install: pqenv
	install -d $(BIN)
	install -m 0755 pqenv/target/release/pqenv $(BIN)/pqenv

run:
	set -a; . ./.env; set +a; guile whatsappel.scm

clean:
	$(CARGO) clean --manifest-path pqenv/Cargo.toml || true
	rm -f *.elc /tmp/whatsappel.go

audit:
	audit/security-audit.sh
