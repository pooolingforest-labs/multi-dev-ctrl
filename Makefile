APP_NAME = MultiDevCtrl
BUNDLE_ID = com.woojin.multi-dev-ctrl
APP_DIR = /Applications/$(APP_NAME).app
CONTENTS = $(APP_DIR)/Contents
MACOS = $(CONTENTS)/MacOS

.PHONY: build install uninstall

build:
	swift build -c release

install: build
	@echo "Installing $(APP_NAME).app..."
	@mkdir -p "$(MACOS)"
	@cp .build/release/multi-dev-ctrl "$(MACOS)/$(APP_NAME)"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleExecutable" "$(CONTENTS)/Info.plist" 2>/dev/null; true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $(APP_NAME)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIdentifier" "$(CONTENTS)/Info.plist" 2>/dev/null; true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleName" "$(CONTENTS)/Info.plist" 2>/dev/null; true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleName string $(APP_NAME)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundlePackageType" "$(CONTENTS)/Info.plist" 2>/dev/null; true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$(CONTENTS)/Info.plist" 2>/dev/null; true
	@/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" "$(CONTENTS)/Info.plist" 2>/dev/null; true
	@/usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string 'MultiDevCtrl needs to control iTerm for terminal management.'" "$(CONTENTS)/Info.plist"
	@echo "Installed to $(APP_DIR)"
	@pkill -f "$(APP_NAME)" 2>/dev/null || true
	@sleep 0.5
	@open "$(APP_DIR)"
	@echo "Launched $(APP_NAME)"
	@echo ""
	@echo "To auto-launch on login:"
	@echo "  System Settings > General > Login Items > add MultiDevCtrl"

uninstall:
	@echo "Stopping $(APP_NAME)..."
	@pkill -f "$(APP_NAME)" 2>/dev/null || true
	@echo "Removing $(APP_DIR)..."
	@rm -rf "$(APP_DIR)"
	@echo "Done."
