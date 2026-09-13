APP_NAME = Postmark
BUNDLE_NAME = Postmark
BUNDLE_ID = ltd.colson.postmark
VERSION = 0.2.0
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE = $(APP_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)
ICONSET = Postmark/Resources/Assets.xcassets/AppIcon.appiconset
# Release/distribution config. Never commit credentials to this repo:
# * Developer ID + team id live in Makefile.local (gitignored).
# * The notary password / API key is stored in the macOS keychain ONLY, via
#   `make notary-login` (profiles are named, never value-bearing here).
#   See Makefile.local.example.
-include Makefile.local

# Set to your Developer ID for distribution, or leave empty for ad-hoc
SIGNING_IDENTITY ?=
# Set to your Apple ID for notarization
APPLE_ID ?=
TEAM_ID ?=
# notarytool keychain profile (created by `make notary-login`)
KEYCHAIN_PROFILE ?= PostmarkNotary
SPARKLE_PRIV_KEY ?=

.PHONY: build run clean release dmg sign notarize release-dmg install uninstall render-icon appcast test setup notary-login

# Render the app icon slices from scripts/render-icon.swift. No-op when slices
# are already newer than the script.
render-icon:
	@if [ "$(ICONSET)/Contents.json" -nt scripts/render-icon.swift ] && [ -n "$$(ls $(ICONSET)/app-icon-512x512@1x.png 2>/dev/null)" ]; then \
		echo "✅ Icon slices up to date"; \
	else \
		swift scripts/render-icon.swift; \
	fi

# Generate the Sparkle appcast XML (public, OSS-friendly) from the latest GitHub
# release. The feed lives in the public GitHub release assets; this target turns
# the release metadata into a Sparkle-edition appcast. Run after a release.
appcast:
	@python3 scripts/generate-appcast.py

# Development build (assumes icon rendered)
build: render-icon
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	xcodebuild -project $(BUNDLE_NAME).xcodeproj \
		-scheme $(BUNDLE_NAME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		ENABLE_DEBUG_DYLIB=NO \
		CODE_SIGNING_ALLOWED=NO \
		build
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(BUNDLE_NAME).app/Contents/MacOS/$(BUNDLE_NAME)" "$(EXECUTABLE)"
	@if [ -d "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(BUNDLE_NAME).app/Contents/PlugIns" ]; then \
		mkdir -p "$(APP_BUNDLE)/Contents/PlugIns" && \
		cp -R "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(BUNDLE_NAME).app/Contents/PlugIns/." "$(APP_BUNDLE)/Contents/PlugIns/"; \
		codesign --force --sign - \
			--entitlements PostmarkMail/PostmarkMail.entitlements \
			"$(APP_BUNDLE)/Contents/PlugIns/PostmarkMail.appex"; \
	fi
	@codesign --force --sign - \
		--entitlements Postmark/Entitlements/Postmark.entitlements \
		"$(EXECUTABLE)"
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(BUNDLE_NAME).app/Contents/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	@cp Postmark/Resources/PostmarkRules.json.template "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	@cp Postmark/App/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $(BUNDLE_NAME)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleName string $(APP_NAME)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $(APP_NAME)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@echo "\n✅ Built: $(APP_BUNDLE)"

# Release build (optimized, universal: arm64 + x86_64)
release: render-icon
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	xcodebuild -project $(BUNDLE_NAME).xcodeproj \
		-scheme $(BUNDLE_NAME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		ARCHS="arm64 x86_64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=NO \
		build
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/Contents/MacOS/$(BUNDLE_NAME)" "$(EXECUTABLE)"
	@if [ -d "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/Contents/PlugIns" ]; then \
		mkdir -p "$(APP_BUNDLE)/Contents/PlugIns" && \
		cp -R "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/Contents/PlugIns/." "$(APP_BUNDLE)/Contents/PlugIns/"; \
		codesign --force --sign - \
			--entitlements PostmarkMail/PostmarkMail.entitlements \
			"$(APP_BUNDLE)/Contents/PlugIns/PostmarkMail.appex"; \
	fi
	@codesign --force --sign - \
		--entitlements Postmark/Entitlements/Postmark.entitlements \
		"$(EXECUTABLE)"
	@lipo "$(EXECUTABLE)" -verify_arch arm64 x86_64 || \
		{ echo "❌ Expected universal binary, got: $$(lipo -archs "$(EXECUTABLE)")"; exit 1; }
	@echo "Architectures: $$(lipo -archs "$(EXECUTABLE)")"
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/Contents/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	@cp Postmark/Resources/PostmarkRules.json.template "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	@cp Postmark/App/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $(BUNDLE_NAME)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleName string $(APP_NAME)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $(APP_NAME)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@echo "\n✅ Release built: $(APP_BUNDLE)"

# One-time local config. Creates Makefile.local from the example (gitignored,
# no secrets: notary credentials live in the keychain, not in files).
setup:
	@if [ ! -f Makefile.local ]; then \
		cp Makefile.local.example Makefile.local; \
		echo "✅ Created Makefile.local — edit SIGNING_IDENTITY + TEAM_ID, then run: make notary-login"; \
	else \
		echo "Makefile.local already exists."; \
	fi

# Store notary credentials in the macOS keychain. You will be prompted for your
# Apple ID app-specific password — it is never written to the repo or to
# Makefile.local; only the named profile (KEYCHAIN_PROFILE) is referenced.
notary-login:
	@test -n "$(APPLE_ID)" || { echo "❌ Set APPLE_ID in Makefile.local (copy from Makefile.local.example)"; exit 1; }
	@test -n "$(TEAM_ID)" || { echo "❌ Set TEAM_ID in Makefile.local"; exit 1; }
	@echo "Storing notary credentials in the keychain as '$(KEYCHAIN_PROFILE)'…"
	xcrun notarytool store-credentials "$(KEYCHAIN_PROFILE)" --apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)"
	@echo "✅ Credentials stored. Now run: make release-dmg"

# Code sign (for distribution outside App Store). Xcode does the signing so
# EVERY component — including the PostmarkMail.appex — gets its own
# entitlements and hardened runtime (--deep re-signing would stamp the appex
# with the daemon's entitlements and break notarization).
sign:
	@test -n "$(SIGNING_IDENTITY)" || { echo "❌ SIGNING_IDENTITY unset — put it in Makefile.local (see Makefile.local.example)"; exit 1; }
	@test -n "$(TEAM_ID)" || { echo "❌ TEAM_ID unset — put it in Makefile.local"; exit 1; }
	xcodebuild -project $(BUNDLE_NAME).xcodeproj -scheme $(BUNDLE_NAME) \
		-configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
		CODE_SIGN_IDENTITY="$(SIGNING_IDENTITY)" DEVELOPMENT_TEAM="$(TEAM_ID)" \
		ENABLE_HARDENED_RUNTIME=YES \
		build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)"
	@cp -R "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/." "$(APP_BUNDLE)/"
	@cp Postmark/Resources/PostmarkRules.json.template "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	@codesign --verify --deep --strict "$(APP_BUNDLE)" && echo "✅ Signed + verified: $(APP_BUNDLE)"

# Notarize (requires Apple Developer account + `make notary-login` once).
notarize: sign
	@xcrun notarytool history --keychain-profile "$(KEYCHAIN_PROFILE)" >/dev/null 2>&1 || { echo "❌ keychain profile '$(KEYCHAIN_PROFILE)' not found — run: make notary-login"; exit 1; }
	@echo "Creating ZIP for notarization…"
	@rm -f "$(BUILD_DIR)/$(BUNDLE_NAME).zip"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(BUNDLE_NAME).zip"
	xcrun notarytool submit "$(BUILD_DIR)/$(BUNDLE_NAME).zip" --keychain-profile "$(KEYCHAIN_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	@spctl -a -vv "$(APP_BUNDLE)"
	@echo "✅ Notarized and stapled: $(APP_BUNDLE)"

# Create DMG for distribution (from the signed app)
dmg: sign
	@rm -f "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	./scripts/create-dmg.sh "$(APP_NAME)" "$(APP_BUNDLE)" "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	@echo "✅ DMG created: $(BUILD_DIR)/$(BUNDLE_NAME).dmg"

# Full distribution: sign → notarize+staple app → DMG → sign DMG → notarize+staple DMG
release-dmg: notarize
	@test -n "$(SIGNING_IDENTITY)" || { echo "❌ SIGNING_IDENTITY unset — see Makefile.local.example"; exit 1; }
	@rm -f "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	./scripts/create-dmg.sh "$(APP_NAME)" "$(APP_BUNDLE)" "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	xcrun notarytool submit "$(BUILD_DIR)/$(BUNDLE_NAME).dmg" --keychain-profile "$(KEYCHAIN_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	@spctl -a -vv --type open --context context:primary-signature "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	@echo "✅ Distribution-ready DMG: $(BUILD_DIR)/$(BUNDLE_NAME).dmg"

# Build and run
run: build
	@open "$(APP_BUNDLE)"

# Install to /Applications
install: sign
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "✅ Installed to /Applications/$(APP_NAME).app"

# Uninstall from /Applications
uninstall:
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "✅ Removed /Applications/$(APP_NAME).app"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	@echo "✅ Cleaned"
