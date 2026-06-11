PROJECT := Linko.xcodeproj
SCHEME := LinkoApp
CONFIG := Debug

.PHONY: gen build test fetch-core run clean archive release dmg bump-version

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

# --- Release pipeline (Developer ID; see docs/RELEASE.md) -----------------
# archive: Release archive + Developer ID export + nested re-sign.
# release: archive -> notarize app -> signed DMG -> notarize DMG.
# Both delegate to scripts/release.sh (which runs `xcodegen generate` itself).
archive:
	./scripts/release.sh archive

release:
	./scripts/release.sh release

dmg:
	./scripts/release.sh dmg

# Bump the shared app version in project.yml and regenerate the project.
# Usage: make bump-version VERSION=0.2.0 [BUILD=20260611001]
bump-version:
	@if [ -z "$(VERSION)" ]; then \
	  echo "usage: make bump-version VERSION=x.y.z [BUILD=n]" >&2; exit 1; \
	fi
	./scripts/bump-version.sh $(VERSION) $(BUILD)

clean:
	rm -rf $(PROJECT) DerivedData
	cd packages/LinkoKit && swift package clean
