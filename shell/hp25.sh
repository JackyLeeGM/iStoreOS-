#!/bin/bash
set -e

# 1. 定义 25.12 (snapshots) 的 APK 源基准地址
BASE_MIRROR="https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages"

# 平台架构列表
declare -A PLATFORMS=(
  ["x86_64"]="${BASE_MIRROR}/x86_64"
  ["aarch64_generic"]="${BASE_MIRROR}/aarch64_generic"
  ["aarch64_cortex-a53"]="${BASE_MIRROR}/aarch64_cortex-a53"
)

# 各类包对应的子仓库 (luci / packages)
declare -A PACKAGE_SOURCES=(
  ["luci-app-homeproxy"]="luci"
  ["luci-i18n-homeproxy-zh-cn"]="luci"
  ["sing-box"]="packages"
)

OUT_DIR=$(pwd)
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for platform in "${!PLATFORMS[@]}"; do
  BASE_URL="${PLATFORMS[$platform]}"
  SAVE_DIR="${OUT_DIR}/${platform}"
  mkdir -p "$SAVE_DIR"

  echo "📦 正在处理平台: $platform"

  for keyword in "${!PACKAGE_SOURCES[@]}"; do
    subdir="${PACKAGE_SOURCES[$keyword]}"
    URL="${BASE_URL}/${subdir}"
    INDEX_TAR="${TMP_DIR}/${platform}_${subdir}_APKINDEX.tar.gz"
    EXTRACT_DIR="${TMP_DIR}/${platform}_${subdir}_index"
    mkdir -p "$EXTRACT_DIR"

    echo "🔍 从 APKINDEX.tar.gz 查找 $keyword"

    # 下载并解压 25.12 的 APKINDEX.tar.gz
    if ! curl -fsL "${URL}/APKINDEX.tar.gz" -o "$INDEX_TAR"; then
      echo "⚠️ 无法获取 ${URL}/APKINDEX.tar.gz"
      continue
    fi

    tar -zxf "$INDEX_TAR" -C "$EXTRACT_DIR"

    # 从 APKINDEX 文本文件中查找精准包名 (格式为 P:包名 \n V:版本号)
    FILE=$(awk -v kw="$keyword" '
      BEGIN { P=""; V="" }
      /^P:/ { P=$2 }
      /^V:/ { V=$2 }
      /^$/ {
        if (P == kw) {
          print P "-" V ".apk"
          exit
        }
        P=""; V=""
      }
    ' "$EXTRACT_DIR/APKINDEX")

    if [ -n "$FILE" ]; then
      echo "⬇️ 正在下载: $FILE"
      if curl -fsL -o "${SAVE_DIR}/${FILE}" "${URL}/${FILE}"; then
        # 🚧 兼容文件名中波浪号 ~ 处理
        if [[ "$FILE" == *"~"* ]]; then
          NEW_FILE=$(echo "$FILE" | tr '~' '-')
          mv "${SAVE_DIR}/${FILE}" "${SAVE_DIR}/${NEW_FILE}"
          echo "🔧 已重命名为: $NEW_FILE"
        fi
      else
        echo "❌ 下载失败: ${FILE}"
      fi
    else
      echo "❌ 未找到匹配包: $keyword"
    fi
  done
done

echo "✅ 下载完成，文件已分别存入 x86_64、aarch64_generic、aarch64_cortex-a53 目录中。"
