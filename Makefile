.PHONY: gen build run test kit-test uiux-test ssh-test mobile-build clean release install

# HerdrMobile / HerdrSSH are arm64-only (libssh2 + OpenSSL xcframeworks).
# Keep code signing on so Simulator Keychain (device SSH key) works; unsigned
# builds log errSecMissingEntitlement (-34018) on every launch.
MOBILE_BUILD = xcodebuild -project HerdrM.xcodeproj -scheme HerdrMobile \
	-configuration Debug \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath build-ios build \
	-skipPackagePluginValidation \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64

SSH_TEST = cd Packages/HerdrSSH && xcodebuild test \
	-scheme HerdrSSH \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath ../../build/HerdrSSHDerivedData \
	-collect-test-diagnostics never \
	-parallel-testing-enabled NO

CODE_SIGN_IDENTITY ?= -

gen:
	xcodegen generate

build: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5

# Optimised build, ad-hoc signed. The project enables the hardened runtime, whose
# library validation refuses the bundled Sparkle/Tailcat frameworks when the app
# has no Team ID (dyld: "different Team IDs"), so the tree is re-signed without
# the runtime option — fine for a locally built copy, not for distribution.
release: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Release -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5
	codesign --force --deep --sign - build/Build/Products/Release/herdrm.app

# Replace /Applications/HerdrM.app with the local Release build (backs up the
# previous copy next to it once, as HerdrM.previous.app).
install: release
	pkill -x herdrm || true
	sleep 1
	if [ -d /Applications/HerdrM.app ] && [ ! -d /Applications/HerdrM.previous.app ]; then ditto /Applications/HerdrM.app /Applications/HerdrM.previous.app; fi
	rm -rf /Applications/HerdrM.app
	ditto build/Build/Products/Release/herdrm.app /Applications/HerdrM.app
	open /Applications/HerdrM.app

# `open` only activates an already-running app, so a rebuilt binary would never
# be exercised. Quit the previous Debug instance first (the /Applications copy is untouched).
run: build
	pkill -f 'build/Build/Products/Debug/herdrm.app/Contents/MacOS/herdrm' || true
	sleep 1
	open build/Build/Products/Debug/herdrm.app

# HerdrM UI/UX tests (HerdrMTests, hosted in the app): sidebar behavior through the real SidebarView.
UIUX_TEST = xcodebuild test \
	-project HerdrM.xcodeproj \
	-scheme HerdrM \
	-configuration Debug \
	-derivedDataPath build \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
	-skipPackagePluginValidation

uiux-test: gen
	$(UIUX_TEST)

kit-test:
	cd Packages/HerdrKit && swift test

# HerdrSSH Swift Testing on iOS Simulator (Session-driver e2e skips without a live sshd fixture).
ssh-test:
	$(SSH_TEST)

# Compile gate for HerdrMobile + HerdrSSH.
mobile-build: gen
	$(MOBILE_BUILD)

test: kit-test

clean:
	rm -rf build build-ios build/HerdrSSHDerivedData HerdrM.xcodeproj \
		Packages/HerdrKit/.build Packages/HerdrSSH/.build
