# NotchActivity
#
#   make install     build, copy to /Applications, and launch
#   make run         build and launch from ./build (no install)
#   make cli         put the `notch` command on your PATH
#   make uninstall   remove the app and the command
#
# Set CODESIGN_IDENTITY to sign with your own certificate (default is ad-hoc).

APP      := build/NotchActivity.app
DEST     := /Applications/NotchActivity.app
CLI_DIR  ?= /usr/local/bin
LSREG    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all app install run cli uninstall icon clean

all: app

app:
	@Scripts/bundle.sh

install: app
	@pkill -x NotchActivity 2>/dev/null || true
	@rm -rf "$(DEST)"
	@cp -R "$(APP)" "$(DEST)"
	@$(LSREG) -f "$(DEST)"
	@open "$(DEST)"
	@echo "==> Installed and launched $(DEST)"
	@echo "    Optional: 'make cli' adds the notch command to $(CLI_DIR)"

run: app
	@pkill -x NotchActivity 2>/dev/null || true
	@open "$(APP)"

cli:
	@test -d "$(DEST)" || { echo "Run 'make install' first."; exit 1; }
	@mkdir -p "$(CLI_DIR)" 2>/dev/null || true
	@ln -sf "$(DEST)/Contents/Resources/notch" "$(CLI_DIR)/notch" 2>/dev/null \
		|| sudo ln -sf "$(DEST)/Contents/Resources/notch" "$(CLI_DIR)/notch"
	@echo "==> Linked $(CLI_DIR)/notch — try: notch alert Hello"

uninstall:
	@pkill -x NotchActivity 2>/dev/null || true
	@rm -rf "$(DEST)"
	@rm -f "$(CLI_DIR)/notch" 2>/dev/null || sudo rm -f "$(CLI_DIR)/notch"
	@echo "==> Removed NotchActivity"

icon:
	@swift Scripts/make-icon.swift

clean:
	@rm -rf .build build
