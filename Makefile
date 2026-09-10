.PHONY: gen build run test kit-test clean

CODE_SIGN_IDENTITY ?= -

gen:
	xcodegen generate

build: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5

run: build
	open build/Build/Products/Debug/herdrm.app

kit-test:
	cd Packages/HerdrKit && swift test

test: kit-test

clean:
	rm -rf build HerdrM.xcodeproj Packages/HerdrKit/.build
