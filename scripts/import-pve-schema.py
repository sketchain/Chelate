#!/usr/bin/env python3
"""Converts the Proxmox VE API viewer data (pve-docs `api-viewer/apidata.js`) into the JSON file
the PVEKit generator reads (`Schema/pve-api-<version>.json`).

    scripts/import-pve-schema.py <apidata.js> <pve-docs commit> <pve-docs version> [output]

`apidata.js` is plain JavaScript of the form `const apiSchema = [ ... ];`. The array is kept as is
(no field is dropped) and written with sorted keys so later imports produce readable diffs. The
source commit is recorded in the file itself and must also be noted in `Schema/README.md`.
"""
import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    source, commit, version = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    major_minor = ".".join(version.split(".")[:2])
    root = pathlib.Path(__file__).resolve().parent.parent
    output = pathlib.Path(sys.argv[4]) if len(sys.argv) == 5 else root / "Schema" / f"pve-api-{major_minor}.json"

    text = source.read_text(encoding="utf-8")
    start, end = text.index("["), text.rindex("]")
    schema = json.loads(text[start:end + 1])
    document = {
        "source": {
            "repository": "https://github.com/proxmox/pve-docs",
            "file": "api-viewer/apidata.js",
            "commit": commit,
            "pveDocsVersion": version,
        },
        "schema": schema,
    }
    output.write_text(json.dumps(document, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {output} ({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
