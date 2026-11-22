#!/usr/bin/env bash
# Version helpers shared by the workflows.
#
#   scripts/version.sh latest-released   → X.Y.Z of the highest vX.Y.Z tag, or 0.0.0
#   scripts/version.sh next-release      → next vX.Y.Z for the MAJOR.MINOR in ./VERSION
#   scripts/version.sh previous-tag TAG  → highest vX.Y.Z tag below TAG (empty if none)
set -euo pipefail

cd "$(dirname "$0")/.."

semver_tags() {
  git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true
}

case "${1:-}" in
  latest-released)
    latest="$(semver_tags | tail -n 1)"
    echo "${latest:-v0.0.0}" | sed 's/^v//'
    ;;
  next-release)
    base="$(tr -d '[:space:]' < VERSION)"
    if ! [[ "$base" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "VERSION must contain MAJOR.MINOR, got '$base'" >&2
      exit 1
    fi
    last_patch="$(semver_tags | grep -E "^v${base//./\\.}\.[0-9]+$" | sed -E 's/^v[0-9]+\.[0-9]+\.//' | sort -n | tail -n 1 || true)"
    if [[ -z "$last_patch" ]]; then
      echo "$base.0"
    else
      echo "$base.$((last_patch + 1))"
    fi
    ;;
  previous-tag)
    current="${2:?tag required}"
    # Sort all tags plus the current one and take the entry just before it.
    { semver_tags; echo "$current"; } | sort -V -u | grep -B1 -x "$current" | grep -vx "$current" || true
    ;;
  *)
    echo "usage: $0 latest-released | next-release | previous-tag TAG" >&2
    exit 2
    ;;
esac
