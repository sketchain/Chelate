# PVE API schema

`pve-api-9.2.json` is the Proxmox VE API viewer data, converted from JavaScript to JSON by
`scripts/import-pve-schema.py`. PVEKit's request layer (`Packages/PVEKit/Sources/PVEKit/Generated/`)
is generated from it by `scripts/generate-pvekit-api.py`.

| | |
| --- | --- |
| Source | [proxmox/pve-docs](https://github.com/proxmox/pve-docs) (GitHub mirror), `api-viewer/apidata.js` |
| Commit | `f31f02702a101714151291e9e163dd31fe8d1aab` (“bump version to 9.2.22”, 2026-11-24) |
| pve-docs version | 9.2.22 (PVE 9.2) |

The commit is also stored in the JSON (`source.commit`) and exposed as `PVEAPI.schemaCommit`.

## Updating

```sh
git clone https://github.com/proxmox/pve-docs && cd pve-docs && git checkout <commit>
python3 ../Chelate/scripts/import-pve-schema.py api-viewer/apidata.js "$(git rev-parse HEAD)" <pve-docs version>
cd ../Chelate
python3 scripts/generate-pvekit-api.py
(cd Packages/PVEKit && swift test)
```

Then update the table above. The generator needs no network access; CI re-runs it and fails if the
committed Swift files differ from its output.
