.PHONY: gen build run test kit-test clean

# project.yml pins the maintainer's Developer ID for Debug so dev builds keep
# entitlement-backed features (UserNotifications) working. Contributors don't
# have that certificate, and xcodegen rewrites the project on every build, so an
# Xcode-side signing change never survives. Fall back to ad-hoc signing when the
# certificate isn't in the Keychain.
#
# Ad-hoc, not unsigned: arm64 refuses to exec a binary with no signature at all,
# so CODE_SIGNING_ALLOWED=NO produces an app that cannot launch. The tradeoff is
# that ad-hoc builds lose entitlement-backed features.
SIGN_ID := Developer ID Application: MOE AI LLC (NCFNX3LJ83)
HAVE_SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -c 'NCFNX3LJ83')
ifeq ($(HAVE_SIGN_ID),0)
SIGN_FLAGS := CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
endif

XCODEBUILD := xcodebuild -project HerdrM.xcodeproj -scheme HerdrM \
	-configuration Debug -derivedDataPath build -skipPackagePluginValidation

gen:
	xcodegen generate

build: gen
ifeq ($(HAVE_SIGN_ID),0)
	@echo "note: '$(SIGN_ID)' not in the Keychain — signing ad-hoc."
	@echo "      UserNotifications and other entitlement-backed features will not work."
endif
	$(XCODEBUILD) $(SIGN_FLAGS) build | tail -5

run: build
	open build/Build/Products/Debug/herdrm.app

kit-test:
	cd Packages/HerdrKit && swift test

test: kit-test

clean:
	rm -rf build HerdrM.xcodeproj Packages/HerdrKit/.build
