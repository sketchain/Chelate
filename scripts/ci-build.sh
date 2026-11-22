#!/usr/bin/env bash
# Shared build pipeline for CI (dev) and release:
#   swift test (PVEKit) → xcodegen → xcodebuild build + test (simulator)
#   → archive (CODE_SIGNING_ALLOWED=NO) → Payload/Chelate.app → unsigned .ipa
#
# Required environment:
#   MARKETING_VERSION   e.g. 0.1.3
#   BUILD_NUMBER        CURRENT_PROJECT_VERSION (github.run_number)
#   GIT_SHA             short commit sha
#   CHANNEL             dev | release
#   IPA_NAME            output file name, written to ./build/
set -euo pipefail

: "${MARKETING_VERSION:?}" "${BUILD_NUMBER:?}" "${GIT_SHA:?}" "${CHANNEL:?}" "${IPA_NAME:?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

COMMON_SETTINGS=(
  "MARKETING_VERSION=$MARKETING_VERSION"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  "CHELATE_GIT_SHA=$GIT_SHA"
  "CHELATE_CHANNEL=$CHANNEL"
)
COMMON_FLAGS=(
  -project Chelate.xcodeproj
  -scheme Chelate
  -skipPackagePluginValidation
  -skipMacroValidation
  -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
)

group "Toolchain"
xcodebuild -version
swift --version
endgroup

group "PVEKit: swift test"
(cd Packages/PVEKit && swift test)
endgroup

group "Generate Xcode project"
xcodegen generate
endgroup

group "Resolve packages"
xcodebuild -resolvePackageDependencies "${COMMON_FLAGS[@]}"
endgroup

group "Pick simulator"
SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((version, device["name"], device["udid"]))
if not candidates:
    sys.exit("no iPhone simulator available")
# Newest runtime first, then name order.
candidates.sort(key=lambda c: (-c[0][0], -c[0][1], c[1]))
version, name, udid = candidates[0]
print(f"Using {name} (iOS {version[0]}.{version[1]})", file=sys.stderr)
print(udid)
')"
endgroup

group "xcodebuild build + test"
xcodebuild build test \
  "${COMMON_FLAGS[@]}" \
  -configuration Debug \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$BUILD_DIR/DerivedData-test" \
  -resultBundlePath "$BUILD_DIR/TestResults.xcresult" \
  "${COMMON_SETTINGS[@]}"
endgroup

group "Archive (unsigned)"
xcodebuild archive \
  "${COMMON_FLAGS[@]}" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$BUILD_DIR/Chelate.xcarchive" \
  -derivedDataPath "$BUILD_DIR/DerivedData-archive" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  "${COMMON_SETTINGS[@]}"
endgroup

group "Package ipa"
APP="$BUILD_DIR/Chelate.xcarchive/Products/Applications/Chelate.app"
test -d "$APP" || { echo "missing $APP"; exit 1; }
STAGE="$BUILD_DIR/ipa"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" \
  -c "Print :ChelateChannel" -c "Print :ChelateGitCommit" "$STAGE/Payload/Chelate.app/Info.plist"
(cd "$STAGE" && rm -f "$BUILD_DIR/$IPA_NAME" && zip -qry "$BUILD_DIR/$IPA_NAME" Payload)
ls -l "$BUILD_DIR/$IPA_NAME"
endgroup
