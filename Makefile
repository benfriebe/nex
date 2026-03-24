.PHONY: lint lint-fix format format-check build test check archive sign notarize dmg release clean-release

VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Nex/Info.plist)
BUILD_DIR = build
ARCHIVE_PATH = $(BUILD_DIR)/Nex.xcarchive
APP_PATH = $(BUILD_DIR)/Nex.app
DMG_PATH = $(BUILD_DIR)/Nex-$(VERSION).dmg
SIGNING_IDENTITY = Developer ID Application: BENJAMIN RYAN FRIEBE (4ASXCG2599)
NOTARIZE_PROFILE = nex-notarize

lint:
	swiftlint lint

lint-fix:
	swiftlint lint --fix

format:
	swiftformat .

format-check:
	swiftformat --lint .

build:
	xcodegen generate --spec project.yml
	xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation build

test:
	xcodebuild -scheme NexTests -destination 'platform=macOS' -skipMacroValidation test

check: format-check lint build test

# --- Release targets ---

archive:
	xcodegen generate --spec project.yml
	xcodebuild archive \
		-scheme Nex \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		-skipMacroValidation \
		CURRENT_PROJECT_VERSION=$(VERSION) \
		MARKETING_VERSION=$(VERSION)
	mkdir -p $(BUILD_DIR)
	cp -R $(ARCHIVE_PATH)/Products/Applications/Nex.app $(APP_PATH)

sign: archive
	codesign --force --deep --sign "$(SIGNING_IDENTITY)" --timestamp --options runtime \
		--entitlements Nex/Nex.entitlements $(APP_PATH)
	codesign --verify --verbose $(APP_PATH)

notarize: sign
	ditto -c -k --keepParent $(APP_PATH) $(BUILD_DIR)/Nex.zip
	xcrun notarytool submit $(BUILD_DIR)/Nex.zip \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple $(APP_PATH)
	rm $(BUILD_DIR)/Nex.zip

dmg: notarize
	rm -f $(DMG_PATH)
	create-dmg \
		--volname "Nex" \
		--window-pos 200 120 \
		--window-size 600 400 \
		--icon-size 100 \
		--icon "Nex.app" 150 190 \
		--app-drop-link 450 190 \
		$(DMG_PATH) $(APP_PATH)

release: dmg
	@echo "Release built: $(DMG_PATH)"
	@echo "Next: tag and push to trigger the GitHub release workflow"
	@echo "  git tag v$(VERSION) && git push origin v$(VERSION)"

clean-release:
	rm -rf $(BUILD_DIR)
