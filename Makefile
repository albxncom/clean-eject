APP_NAME := CleanEject
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP)/Contents
HELPER := $(CONTENTS)/Helpers/cleaneject
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
CLI_LINK := $(HOME)/.local/bin/cleaneject
ICNS := Resources/AppIcon.icns
PLISTBUDDY := /usr/libexec/PlistBuddy
# swift build records the deployment target (14.0) as the linked SDK in LC_BUILD_VERSION, and AppKit keys the
# macOS 26 design (Liquid Glass) on that field, so the bare binary renders the legacy look. Pass the real SDK.
SDK_VERSION := $(shell xcrun --sdk macosx --show-sdk-version)
# TCC (Full Disk Access) stores the app's code requirement; an ad-hoc signature changes with every build and the
# grant silently stops matching. Sign with the first valid Apple Development identity when there is one.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | grep -v CSSMERR | head -1 | awk '{print $$2}')
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY := -
endif
SWIFT_BUILD := swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker $(SDK_VERSION)

.PHONY: all app build test icon run install clean

all: app

build:
	$(SWIFT_BUILD)

test:
	swift test

app: build
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Helpers"
	cp "$$($(SWIFT_BUILD) --show-bin-path)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	# The product is CleanEjectCLI: "cleaneject" would collide with CleanEject on a case-insensitive file system.
	cp "$$($(SWIFT_BUILD) --show-bin-path)/CleanEjectCLI" "$(HELPER)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	$(PLISTBUDDY) -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"
	if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(CONTENTS)/Resources/"; else $(PLISTBUDDY) -c "Delete :CFBundleIconFile" "$(CONTENTS)/Info.plist"; fi
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	# Nested code first, then the bundle (which seals it); --deep would re-sign the helper with defaults.
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID).cli" "$(HELPER)"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	@echo "Built $(APP), signed with $(SIGN_IDENTITY)"

# Regenerates Resources/AppIcon.icns from Scripts/make-icon.swift; the result is committed.
icon:
	rm -rf "$(BUILD_DIR)/AppIcon.iconset"
	swift Scripts/make-icon.swift "$(BUILD_DIR)/AppIcon.iconset"
	iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(ICNS)"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	# Re-scan NSServices so Finder lists "Clean with CleanEject" without a logout.
	/System/Library/CoreServices/pbs -update
	# Same rule as Settings > General: create or replace only a missing link or one to a CleanEject helper.
	@dest="$$(readlink "$(CLI_LINK)" 2>/dev/null)"; \
	if [ ! -e "$(CLI_LINK)" ] && [ ! -L "$(CLI_LINK)" ] || case "$$dest" in */CleanEject.app/Contents/Helpers/cleaneject) true;; *) false;; esac; then \
		mkdir -p "$$(dirname "$(CLI_LINK)")" && ln -sfn "/Applications/$(APP_NAME).app/Contents/Helpers/cleaneject" "$(CLI_LINK)" && \
		echo "Linked $(CLI_LINK)"; \
	else \
		echo "Not linking $(CLI_LINK): something else is there" >&2; \
	fi

clean:
	rm -rf "$(BUILD_DIR)" .build
