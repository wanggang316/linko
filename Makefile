PROJECT := Linko.xcodeproj
SCHEME := LinkoApp
CONFIG := Debug

.PHONY: gen build test fetch-core run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) CODE_SIGNING_ALLOWED=NO build

test:
	cd packages/LinkoKit && swift test

fetch-core:
	./scripts/fetch-singbox.sh

run: build
	open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/ {print $$3}')/Linko.app"

clean:
	rm -rf $(PROJECT) DerivedData
	cd packages/LinkoKit && swift package clean
