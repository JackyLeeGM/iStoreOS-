#!/bin/bash
set -e

BASE_MIRROR="https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages"

# 平台架构列表（用于 sing-box 等二进制编译包）
declare -A PLATFORMS=(
  ["x86_64"]="${BASE_MIRROR}/x86_64"
  ["aarch64_generic"]="${BASE_MIRROR}/aarch64_generic"
  ["aarch64_cortex-a53"]="${BASE_MIRROR}/aarch64_cortex-a53"
)

OUT_DIR=$(pwd)
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 从指定的 APK 仓库索引中查找并下载包
download_apk() {
  repo_url="$1"
  keyword="$2"
  save_dir="$3"
  
  index_tar="${TMP_DIR}/APKINDEX_$(echo "$repo_url" | md5sum | awk '{print $1}').tar.gz"
  extract_dir="${TMP_DIR}/ext_$(echo "$repo_url" | md5sum | awk '{print $1}')"
  mkdir -p "$extract_dir"

  echo "🔍 正在从 ${repo_url} 查找 $keyword ..."

  if ! curl -fsL "${repo_url}/APKINDEX.tar.gz" -o "$index_tar"; then
    echo "⚠️ 无法获取 ${repo_url}/APKINDEX.tar.gz"
    return 1
  fi

  tar -zxf "$index_tar" -C "$extract_dir"

  # 解析 APKINDEX 获取精准文件名 (P:包名 \n V:版本)
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
  ' "$extract_dir/APKINDEX")

  if [ -n "$FILE" ]; then
    echo "⬇️ 正在下载: $FILE"
    if curl -fsL -o "${save_dir}/${FILE}" "${repo_url}/${FILE}"; then
      if [[ "$FILE" == *"~"* ]]; then
        NEW_FILE=$(echo "$FILE" | tr '~' '-')
        mv "${save_dir}/${FILE}" "${save_dir}/${NEW_FILE}"
        echo "🔧 已重命名为: $NEW_FILE"
      fi
      return 0
    fi
  fi

  echo "❌ 未找到或下载失败: $keyword"
  return 1
}

# 1. 优先下载通用的 Luci 界面与语言包 (来自 all/luci 仓库)
ALL_LUCI_URL="${BASE_MIRROR}/all/luci"
COMMON_TMP="${TMP_DIR}/common_apks"
mkdir -p "$COMMON_TMP"

echo "📦 正在下载通用界面组件 (luci-app-homeproxy)..."
download_apk "$ALL_LUCI_URL" "luci-app-homeproxy" "$COMMON_TMP"
download_apk "$ALL_LUCI_URL" "luci-i18n-homeproxy-zh-cn" "$COMMON_TMP"

# 2. 为各个平台单独处理特定架构依赖 (如 sing-box) 并合成完整目录
for platform in "${!PLATFORMS[@]}"; do
  PLATFORM_URL="${PLATFORMS[$platform]}"
  SAVE_DIR="${OUT_DIR}/${platform}"
  mkdir -p "$SAVE_DIR"

  echo "📦 正在处理平台专属依赖: $platform"

  # 复制通用界面包到平台目录
  cp -f "$COMMON_TMP"/*.apk "$SAVE_DIR/" 2>/dev/null || true

  # 从当前架构的 packages 目录下载 sing-box
  download_apk "${PLATFORM_URL}/packages" "sing-box" "$SAVE_DIR" || true
done

echo "✅ 下载完成，文件已正确保存至各架构目录！"
