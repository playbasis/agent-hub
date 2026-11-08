.PHONY: help doctor bootstrap build test hygiene check run preview screenshots release app install open uninstall hooks

help:
	@echo 'make doctor     check this Mac is ready (read-only)'
	@echo 'make install    build the app and install it in ~/Applications'
	@echo 'make open       open the installed app'
	@echo 'make check      build, test and run the hygiene check'
	@echo 'make run        run the menu-bar app from source'
	@echo 'make preview    open one Hub page beside the installed app (PAGE=Models)'
	@echo 'make screenshots  re-render docs/screenshots from invented demo data (sandboxed)'
	@echo 'make hooks      block pushes that would publish keys or personal paths'
	@echo 'make uninstall  move the app to the Trash (PURGE=1 also moves its data)'

doctor:
	./scripts/doctor.sh

bootstrap:
	swift package --package-path apps/MenuBar resolve

build:
	swift build --package-path apps/MenuBar

test:
	swift test --package-path packages/WorkspaceContracts
	swift test --package-path apps/MenuBar
	@if command -v python3 >/dev/null; then python3 -I scripts/check-workspace-contracts.py; else echo "python3 not found; skipped the workspace contract cross-check"; fi

hygiene:
	./scripts/check-clean.sh

check: build test hygiene

run:
	swift run --package-path apps/MenuBar ClaudeCodexBridgeMenuBar

# Opens one Hub page in a diagnostic window beside an installed copy: make preview PAGE=Models
preview:
	BRIDGE_UI_PREVIEW=1 BRIDGE_REPORTS_PREVIEW=1 BRIDGE_REPORTS_SECTION="$(or $(PAGE),Overview)" swift run --package-path apps/MenuBar ClaudeCodexBridgeMenuBar

# Renders the README screenshots from invented data inside a sandbox that cannot read your home folder.
screenshots:
	./scripts/screenshots.sh $(NAMES)

release:
	swift build -c release --package-path apps/MenuBar

app:
	./scripts/build-app.sh

install: app
	./scripts/install-user.sh
	@echo 'Installed. Open it with: make open'

open:
	open "$$HOME/Applications/ClaudeCodexBridge.app"

uninstall:
	./scripts/uninstall-user.sh $(if $(PURGE),--purge)

hooks:
	git config core.hooksPath .githooks
	@echo 'Pre-push hygiene check enabled.'
