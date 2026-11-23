#!/usr/bin/env bash
# Exports the screenshot attachments (XCTAttachment, lifetime keepAlways) of the UI tests from an
# xcresult bundle as PNG files named "<attachment name>-<short sha>.png".
#
# Usage: scripts/export-screenshots.sh <TestResults.xcresult> <output dir> <short sha>
set -euo pipefail

RESULT="${1:?xcresult path}"
OUT="${2:?output dir}"
SHA="${3:?short sha}"

if [ ! -d "$RESULT" ]; then
  echo "no result bundle at $RESULT, nothing to export"
  exit 0
fi

RAW="$(mktemp -d)"
mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RAW"

python3 - "$RAW" "$OUT" "$SHA" <<'PY'
import json, pathlib, re, shutil, sys

raw, out, sha = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
manifest = json.loads((raw / "manifest.json").read_text())

def attachments(node):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from attachments(value)
    elif isinstance(node, list):
        for value in node:
            yield from attachments(value)

count = 0
for item in attachments(manifest):
    source = raw / item["exportedFileName"]
    if source.suffix.lower() != ".png" or not source.exists():
        continue
    # suggestedHumanReadableName looks like "01-overview_0_<uuid>.png".
    name = item.get("suggestedHumanReadableName") or item.get("name") or source.stem
    name = pathlib.Path(name).stem
    match = re.match(r"^(\d\d-[A-Za-z0-9-]+)", name)
    base = match.group(1) if match else re.sub(r"[^A-Za-z0-9-]+", "-", name).strip("-")
    target = out / f"{base}-{sha}.png"
    n = 2
    while target.exists():
        target = out / f"{base}-{n}-{sha}.png"
        n += 1
    shutil.copyfile(source, target)
    count += 1
    print(target.name)
print(f"exported {count} screenshot(s)")
PY
