#!/bin/bash

# 镜像源列表
MIRRORS=(
  "https://downloads.immortalwrt.org/snapshots/packages"
  "https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages"
)

# 平台架构列表
declare -A PLATFORMS=(
  ["x86_64"]="x86_64"
  ["aarch64_generic"]="aarch64_generic"
  ["aarch64_cortex-a53"]="aarch64_cortex-a53"
)

OUT_DIR=$(pwd)
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

download_apk_multisource() {
  subpath="$1"   # 例如: all/luci 或 x86_64/packages
  keyword="$2"   # 例如: luci-app-homeproxy
  save_dir="$3"  # 目标保存目录

  success=0

  for base_url in "${MIRRORS[@]}"; do
    repo_url="${base_url}/${subpath}"
    hash_id=$(echo "$repo_url" | md5sum | awk '{print $1}')
    index_tar="${TMP_DIR}/APKINDEX_${hash_id}.tar.gz"
    extract_dir="${TMP_DIR}/ext_${hash_id}"
    mkdir -p "$extract_dir"

    echo "🔍 尝试从 ${repo_url} 查找 $keyword ..."

    if curl -fsL --connect-timeout 10 --retry 2 "${repo_url}/APKINDEX.tar.gz" -o "$index_tar"; then
      if tar -zxf "$index_tar" -C "$extract_dir" 2>/dev/null; then
        # 兼容 Windows/Linux 换行符，增强 awk 匹配
        FILE=$(tr -d '\r' < "$extract_dir/APKINDEX" | awk -v kw="$keyword" '
          BEGIN { RS=""; FS="\n" }
          {
            pkg=""; ver=""
            for(i=1;i<=NF;i++) {
              if($i ~ /^P:/) pkg=substr($i,3)
              if($i ~ /^V:/) ver=substr($i,3)
            }
            if(pkg == kw && ver != "") {
              print pkg "-" ver ".apk"
              exit
            }
          }
        ')

        if [ -n "$FILE" ]; then
          echo "⬇️ 正在下载: $FILE"
          if curl -fsL --connect-timeout 15 "${repo_url}/${FILE}" -o "${save_dir}/${FILE}"; then
            if [[ "$FILE" == *"~"* ]]; then
              NEW_FILE=$(echo "$FILE" | tr '~' '-')
              mv "${save_dir}/${FILE}" "${save_dir}/${NEW_FILE}"
              echo "🔧 已重命名为: $NEW_FILE"
            fi
            success=1
            break
          fi
        fi
      fi
    fi
    echo "⚠️ 源 ${repo_url} 查找失败，尝试下一个源..."
  done

  if [ $success -eq 1 ]; then
    return 0
  else
    echo "❌ 无法找到或下载: $keyword"
    return 1
  fi
}

COMMON_TMP="${TMP_DIR}/common_apks"
mkdir -p "$COMMON_TMP"

echo "📦 正在下载通用界面组件 (luci-app-homeproxy)..."
download_apk_multisource "all/luci" "luci-app-homeproxy" "$COMMON_TMP" || true
download_apk_multisource "all/luci" "luci-i18n-homeproxy-zh-cn" "$COMMON_TMP" || true

# 如果 all/luci 没找到，尝试在特定架构的 luci 目录下再找一次备用
if [ -z "$(ls -A "$COMMON_TMP" 2>/dev/null)" ]; then
  echo "⚠️ 通用目录未抓取到，尝试从 x86_64/luci 获取..."
  download_apk_multisource "x86_64/luci" "luci-app-homeproxy" "$COMMON_TMP" || true
  download_apk_multisource "x86_64/luci" "luci-i18n-homeproxy-zh-cn" "$COMMON_TMP" || true
fi

# 处理各平台依赖并分发
for platform in "${!PLATFORMS[@]}"; do
  arch_path="${PLATFORMS[$platform]}"
  SAVE_DIR="${OUT_DIR}/${platform}"
  mkdir -p "$SAVE_DIR"

  echo "📦 正在处理平台专属依赖: $platform"

  # 复制界面包
  cp -f "$COMMON_TMP"/*.apk "$SAVE_DIR/" 2>/dev/null || true

  # 下载当前架构的 sing-box
  download_apk_multisource "${arch_path}/packages" "sing-box" "$SAVE_DIR" || true
done

echo "✅ 文件下载完毕！"
