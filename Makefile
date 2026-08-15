PROJECT := Linko.xcodeproj
SCHEME := LinkoApp
CONFIG := Debug

.PHONY: gen build test test-app fetch-core run clean archive release dmg bump-version \
        site site-dev site-preview

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) CODE_SIGNING_ALLOWED=NO build

test:
	cd packages/LinkoKit && swift test

# App-layer unit tests (LinkoAppTests). Separate from `test` (LinkoKit via
# SwiftPM): this drives xcodebuild against the generated project. The bundle
# is host-free and unsigned, so it runs on any machine without identities.
test-app: gen
	xcodebuild -project $(PROJECT) -scheme LinkoAppTests -configuration $(CONFIG) -destination "platform=macOS" test CODE_SIGNING_ALLOWED=NO

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

# --- Marketing site (apps/website/; see apps/website/README.md) -----------
# The site reads MARKETING_VERSION from project.yml and the release notes from
# CHANGELOG.md at build time, so it never needs its own copy of either.
site:
	cd apps/website && npm ci && npm run check && npm run build

site-dev:
	cd apps/website && npm install && npm run dev

site-preview:
	cd apps/website && npm run preview

clean:
	rm -rf $(PROJECT) DerivedData apps/website/dist
	cd packages/LinkoKit && swift package clean
