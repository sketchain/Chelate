#!/usr/bin/env python3
"""Regenerates App/Resources/Localizable.xcstrings from string literals in App/Sources.

The source language is zh-Hans and the UI is written in Chinese directly in code, so the
catalog mainly serves as the single list of user-facing strings (and the starting point for
future translations). Xcode also syncs this catalog automatically when building in the IDE.

Usage: python3 scripts/extract-strings.py
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "App" / "Sources"
CATALOG = ROOT / "App" / "Resources" / "Localizable.xcstrings"

# Calls whose first string literal argument is localized by SwiftUI or String(localized:).
CALLS = [
    "Text", "Label", "Button", "Section", "LabeledContent", "TextField", "SecureField", "Toggle",
    "Picker", "ProgressView", "navigationTitle", "ContentUnavailableView", "NoPermissionLabel",
    "UsageBar", "confirmationDialog", "alert", "String", "chartSection", "Menu", "accessibilityLabel",
]
CALL_PREFIX_RE = re.compile(r"\b(?:%s)\(\s*(?:localized:\s*|text:\s*|title:\s*)?$" % "|".join(CALLS))
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
INT_EXPRESSIONS = {"status", "keys.count"}


def literals(source: str):
    """Yields (prefix, literal) for every single-line string literal outside comments.
    Interpolations are returned as %@ / %lld placeholders."""
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            i = source.find("\n", i)
            i = n if i < 0 else i
            continue
        if source.startswith("/*", i):
            i = source.find("*/", i)
            i = n if i < 0 else i + 2
            continue
        if source.startswith('"""', i):
            i = source.find('"""', i + 3)
            i = n if i < 0 else i + 3
            continue
        if source[i] == '"':
            start = i
            i += 1
            out = []
            while i < n and source[i] != '"':
                if source[i] == "\\" and i + 1 < n:
                    nxt = source[i + 1]
                    if nxt == "(":
                        depth, j = 1, i + 2
                        while j < n and depth:
                            if source[j] == "(":
                                depth += 1
                            elif source[j] == ")":
                                depth -= 1
                            j += 1
                        expression = source[i + 2:j - 1].strip()
                        out.append("%lld" if expression in INT_EXPRESSIONS else "%@")
                        i = j
                        continue
                    out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
                    i += 2
                    continue
                out.append(source[i])
                i += 1
            i += 1
            line_start = source.rfind("\n", 0, start) + 1
            yield source[line_start:start], "".join(out)
            continue
        i += 1


def main() -> None:
    keys = set()
    for path in sorted(SOURCES.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for prefix, literal in literals(text):
            if CJK_RE.search(literal) or CALL_PREFIX_RE.search(prefix):
                keys.add(literal)
    keys.discard("")

    existing = {}
    if CATALOG.exists():
        existing = json.loads(CATALOG.read_text(encoding="utf-8")).get("strings", {})

    strings = {}
    for key in sorted(keys):
        entry = existing.get(key, {})
        entry.setdefault("extractionState", "manual")
        strings[key] = entry

    catalog = {"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"}
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{len(strings)} strings → {CATALOG.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
