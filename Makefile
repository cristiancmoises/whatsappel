.PHONY: all compile lint clean install install-server install-service test help

EMACS ?= emacs
NODE ?= node
NPM ?= npm
PREFIX ?= $(HOME)/.local

EL_FILES = whatsapp.el
ELC_FILES = $(EL_FILES:.el=.elc)

all: compile ## Build everything

compile: $(ELC_FILES) ## Byte-compile whatsapp.el
	@echo "✓ Byte-compilation complete"

%.elc: %.el
	$(EMACS) --batch \
		--eval "(require 'package)" \
		--eval "(package-initialize)" \
		-L . \
		-f batch-byte-compile $<

lint: ## Check for common issues
	$(EMACS) --batch \
		--eval "(require 'package)" \
		--eval "(package-initialize)" \
		-L . \
		--eval "(require 'checkdoc)" \
		--eval "(setq sentence-end-double-space nil)" \
		-f batch-byte-compile $(EL_FILES)
	@echo "✓ Lint passed"

clean: ## Remove build artifacts
	rm -f $(ELC_FILES)
	@echo "✓ Clean"

install: compile install-server ## Install everything
	@echo "✓ Full install complete"

install-server: ## Install server dependencies
	$(NPM) install --production
	@echo "✓ Server dependencies installed"

install-service: ## Install systemd user service
	mkdir -p $(HOME)/.config/systemd/user
	mkdir -p $(HOME)/.local/share/whatsappel
	cp server.js package.json $(HOME)/.local/share/whatsappel/
	cd $(HOME)/.local/share/whatsappel && $(NPM) install --production
	cp whatsappel.service $(HOME)/.config/systemd/user/
	systemctl --user daemon-reload
	@echo "✓ Service installed"
	@echo "  Enable: systemctl --user enable whatsappel"
	@echo "  Start:  systemctl --user start whatsappel"
	@echo "  Logs:   journalctl --user -u whatsappel -f"

test: ## Run server syntax check and Elisp byte-compile check
	$(NODE) -c server.js
	@echo "✓ server.js syntax OK"
	$(EMACS) --batch \
		--eval "(require 'package)" \
		--eval "(package-initialize)" \
		-L . \
		-f batch-byte-compile $(EL_FILES) 2>&1 | grep -v "^Compiling"
	@echo "✓ whatsapp.el compiles clean"

test-server: ## Run server endpoint tests (requires running server)
	$(NODE) test/test-server.js
	@echo "✓ Server tests passed"

docker-build: ## Build Docker image
	docker build -t whatsappel .
	@echo "✓ Docker image built"

docker-run: ## Run server in Docker
	docker compose up -d
	@echo "✓ Server running (docker compose logs -f to watch)"

docker-stop: ## Stop Docker server
	docker compose down
	@echo "✓ Server stopped"

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
