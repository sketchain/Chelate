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
echo "### 安装包"
echo
echo "| 文件 | 内容 |"
echo "| --- | --- |"
echo "| \`Chelate-$current-unsigned.ipa\` | 标准版：不含小组件，不需要 App Group，只用一份描述文件签名 |"
echo "| \`Chelate-$current-widget-unsigned.ipa\` | 小组件版：内嵌小组件扩展（\`org.sketchain.chelate.widget\`），需要 App Group \`group.org.sketchain.chelate\`，主 App 和扩展各用一份描述文件签名 |"
echo
echo "两个包的 bundle id 相同（\`org.sketchain.chelate\`），用同一证书签名时可以互相覆盖安装，数据保留。均未签名，安装前需自行重签（见 README「签名与安装」）。校验：\`shasum -a 256 -c <文件>.sha256\`"
