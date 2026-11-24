#!/usr/bin/env bash
# Release notes from git log (previous tag → HEAD), grouped by Conventional Commit type.
# Merge commits are excluded.
#
#   scripts/release-notes.sh <previous-tag or empty> <new-tag>
set -euo pipefail

cd "$(dirname "$0")/.."
previous="${1:-}"
current="${2:?new tag required}"

if [[ -n "$previous" ]]; then
  range="$previous..HEAD"
else
  range="HEAD"
fi

feats=()
fixes=()
others=()
while IFS=$'\t' read -r sha subject; do
  [[ -z "$sha" ]] && continue
  line="- $subject ($sha)"
  if [[ "$subject" =~ ^feat(\([^\)]*\))?!?:\  ]]; then
    feats+=("$line")
  elif [[ "$subject" =~ ^fix(\([^\)]*\))?!?:\  ]]; then
    fixes+=("$line")
  else
    others+=("$line")
  fi
done < <(git log --no-merges --pretty=format:'%h%x09%s' "$range"; echo)

echo "## Chelate $current"
echo
if [[ -n "$previous" ]]; then
  echo "Changes since $previous."
else
  echo "First release."
fi
echo
if ((${#feats[@]})); then
  echo "### 新功能 (feat)"
  printf '%s\n' "${feats[@]}"
  echo
fi
if ((${#fixes[@]})); then
  echo "### 修复 (fix)"
  printf '%s\n' "${fixes[@]}"
  echo
fi
if ((${#others[@]})); then
  echo "### 其他"
  printf '%s\n' "${others[@]}"
  echo
fi
echo "---"
echo "未签名 ipa，安装前需自行重签（例如 zsign）。校验：\`shasum -a 256 -c Chelate-$current-unsigned.ipa.sha256\`"
