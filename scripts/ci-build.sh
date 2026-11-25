#!/usr/bin/env bash
# Shared build pipeline for CI (dev) and release. STEPS selects what runs (space separated):
#
#   pvekit   swift test of PVEKit on macOS (optional; CI covers PVEKit in its Linux job)
#   test     widget variant: xcodebuild test on the simulator (unit + screenshot UI tests,
#            UI test classes spread over parallel simulator clones)
#   package  VARIANT: unsigned archive → Payload/Chelate.app (+ PlugIns/*.appex) → .ipa
#
# CI (push / PR) and release run "package" only, one variant per call; the manual test
# workflow (test.yml) runs "test".
#
# Environment:
#   STEPS               default "package"
#   VARIANT             standard | widget (for package; tests always use the widget variant)
#   MARKETING_VERSION   e.g. 0.2.0
#   BUILD_NUMBER        CURRENT_PROJECT_VERSION (git rev-list --count HEAD)
#   GIT_SHA             short commit sha
#   CHANNEL             dev | release
#   IPA_NAME            output file name, written to ./build/ (package only)
set -euo pipefail

STEPS=" ${STEPS:-package} "
VARIANT="${VARIANT:-widget}"
: "${MARKETING_VERSION:?}" "${BUILD_NUMBER:?}" "${GIT_SHA:?}" "${CHANNEL:?}"
has_step() { [[ "$STEPS" == *" $1 "* ]]; }
if has_step package; then : "${IPA_NAME:?}"; fi
if has_step test && [[ "$VARIANT" != widget ]]; then
  echo "tests run on the widget variant only" >&2; exit 2
fi

case "$VARIANT" in
  standard) SCHEME=Chelate ;;
  widget) SCHEME=Chelate-Widget ;;
  *) echo "VARIANT must be standard or widget, got '$VARIANT'" >&2; exit 2 ;;
esac

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
  -scheme "$SCHEME"
  -skipPackagePluginValidation
  -skipMacroValidation
  -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
)

group "Toolchain"
xcodebuild -version
swift --version
endgroup

if has_step pvekit; then
  group "PVEKit: swift test"
  (cd Packages/PVEKit && swift test)
  endgroup
fi

group "Generate Xcode project"
xcodegen generate
endgroup

group "Resolve packages"
xcodebuild -resolvePackageDependencies "${COMMON_FLAGS[@]}"
endgroup

if has_step test; then
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

  group "xcodebuild test"
  # UI test classes (light / dark per screen) run on parallel simulator clones.
  xcodebuild test \
    "${COMMON_FLAGS[@]}" \
    -configuration Debug \
    -destination "id=$SIMULATOR_ID" \
    -parallel-testing-enabled YES \
    -parallel-testing-worker-count "${TEST_WORKERS:-3}" \
    -derivedDataPath "$BUILD_DIR/DerivedData-test" \
    -resultBundlePath "$BUILD_DIR/TestResults.xcresult" \
    "${COMMON_SETTINGS[@]}"
  endgroup
fi

if ! has_step package; then
  exit 0
fi

ARCHIVE="$BUILD_DIR/Chelate-$VARIANT.xcarchive"
group "Archive (unsigned, $VARIANT)"
xcodebuild archive \
  "${COMMON_FLAGS[@]}" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD_DIR/DerivedData-archive-$VARIANT" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  "${COMMON_SETTINGS[@]}"
endgroup

group "Package ipa"
APP="$ARCHIVE/Products/Applications/Chelate.app"
test -d "$APP" || { echo "missing $APP"; exit 1; }
if [[ "$VARIANT" == widget ]]; then
  test -d "$APP/PlugIns/ChelateWidgetExtension.appex" || { echo "widget extension not embedded"; exit 1; }
else
  if [[ -d "$APP/PlugIns" ]]; then echo "standard variant must not contain extensions"; ls "$APP/PlugIns"; exit 1; fi
fi
STAGE="$BUILD_DIR/ipa-$VARIANT"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" \
  -c "Print :ChelateChannel" -c "Print :ChelateGitCommit" "$STAGE/Payload/Chelate.app/Info.plist"
if [[ "$VARIANT" == widget ]]; then
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" \
    "$STAGE/Payload/Chelate.app/PlugIns/ChelateWidgetExtension.appex/Info.plist"
fi
(cd "$STAGE" && rm -f "$BUILD_DIR/$IPA_NAME" && zip -qry "$BUILD_DIR/$IPA_NAME" Payload)
ls -l "$BUILD_DIR/$IPA_NAME"
endgroup
