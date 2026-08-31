APP_NAME = Postmark
BUNDLE_NAME = Postmark
BUNDLE_ID = digital.colson.postmark
VERSION = 0.2.0
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE = $(APP_BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)
ICONSET = Postmark/Resources/Assets.xcassets/AppIcon.appiconset
# Set to your Developer ID for distribution, or leave empty for ad-hoc
SIGNING_IDENTITY ?=
# Set to your Apple ID for notarization
APPLE_ID ?=
TEAM_ID ?=
SPARKLE_PRIV_KEY ?=

.PHONY: build run clean release dmg sign notarize release-dmg install uninstall render-icon appcast test

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
		build
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(BUNDLE_NAME).app/Contents/MacOS/$(BUNDLE_NAME)" "$(EXECUTABLE)"
	@codesign --force --sign - \
		--entitlements Postmark/Entitlements/Postmark.entitlements \
		"$(EXECUTABLE)"
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(BUNDLE_NAME).app/Contents/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
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
		build
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/Contents/MacOS/$(BUNDLE_NAME)" "$(EXECUTABLE)"
	@codesign --force --sign - \
		--entitlements Postmark/Entitlements/Postmark.entitlements \
		"$(EXECUTABLE)"
	@lipo "$(EXECUTABLE)" -verify_arch arm64 x86_64 || \
		{ echo "❌ Expected universal binary, got: $$(lipo -archs "$(EXECUTABLE)")"; exit 1; }
	@echo "Architectures: $$(lipo -archs "$(EXECUTABLE)")"
	@cp "$(BUILD_DIR)/DerivedData/Build/Products/Release/$(BUNDLE_NAME).app/Contents/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
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

# Code sign (for distribution outside App Store)
sign: release
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "⚠️  No SIGNING_IDENTITY set. Ad-hoc signing..."; \
		codesign --force --deep --sign - \
			--entitlements Postmark/Entitlements/Postmark.entitlements \
			"$(APP_BUNDLE)"; \
	else \
		echo "Signing with: $(SIGNING_IDENTITY)"; \
		codesign --force --deep --options runtime \
			--sign "$(SIGNING_IDENTITY)" \
			--entitlements Postmark/Entitlements/Postmark.entitlements \
			"$(APP_BUNDLE)"; \
	fi
	@echo "✅ Signed: $(APP_BUNDLE)"

# Notarize (requires Apple Developer account)
notarize: sign
	@if [ -n "$(APPLE_ID)" ] && [ -n "$(TEAM_ID)" ]; then \
		echo "Creating ZIP for notarization..."; \
		ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(BUNDLE_NAME).zip"; \
		if [ -n "$(KEYCHAIN_PROFILE)" ]; then \
			xcrun notarytool submit "$(BUILD_DIR)/$(BUNDLE_NAME).zip" \
				--keychain-profile "$(KEYCHAIN_PROFILE)" --wait; \
		else \
			xcrun notarytool submit "$(BUILD_DIR)/$(BUNDLE_NAME).zip" \
				--apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)" \
				--password "$(APP_PASSWORD)" --wait; \
		fi; \
		xcrun stapler staple "$(APP_BUNDLE)"; \
		echo "✅ Notarized and stapled: $(APP_BUNDLE)"; \
	else \
		echo "⚠️  Set APPLE_ID, TEAM_ID, and APP_PASSWORD (or KEYCHAIN_PROFILE) to notarize"; \
		echo "   Recommended: xcrun notarytool store-credentials AC_PASSWORD --apple-id ... --team-id ... --password ..."; \
	fi

# Create DMG for distribution
dmg: sign
	@rm -f "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	./scripts/create-dmg.sh "$(APP_NAME)" "$(APP_BUNDLE)" "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	@echo "✅ DMG created: $(BUILD_DIR)/$(BUNDLE_NAME).dmg"

# Full distribution: sign → notarize → staple → DMG → sign DMG → notarize DMG
release-dmg: notarize
	@rm -f "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	./scripts/create-dmg.sh "$(APP_NAME)" "$(APP_BUNDLE)" "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"
	@if [ -n "$(SIGNING_IDENTITY)" ]; then \
		codesign --force --sign "$(SIGNING_IDENTITY)" "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"; \
		if [ -n "$(KEYCHAIN_PROFILE)" ]; then \
			xcrun notarytool submit "$(BUILD_DIR)/$(BUNDLE_NAME).dmg" \
				--keychain-profile "$(KEYCHAIN_PROFILE)" --wait; \
		else \
			xcrun notarytool submit "$(BUILD_DIR)/$(BUNDLE_NAME).dmg" \
				--apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)" \
				--password "$(APP_PASSWORD)" --wait; \
		fi; \
		xcrun stapler staple "$(BUILD_DIR)/$(BUNDLE_NAME).dmg"; \
	elif [ -z "$(APPLE_ID)" ]; then \
		echo "⚠️  No SIGNING_IDENTITY/APPLE_ID set — DMG notarization skipped"; \
	fi
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
