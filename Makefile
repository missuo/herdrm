.PHONY: gen build run test kit-test ssh-test mobile-build clean

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

run: build
	open build/Build/Products/Debug/herdrm.app

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
