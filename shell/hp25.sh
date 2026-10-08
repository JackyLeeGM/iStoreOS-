#!/bin/sh
set -eu

OPENWRT_RELEASE="${OPENWRT_RELEASE:-snapshots}"
OUT_DIR="${OUT_DIR:-dist/homeproxy-run}"
WORK_ROOT="${WORK_ROOT:-/tmp/homeproxy-run-build.$$}"
DEFAULT_ARCHES="x86_64 aarch64_generic aarch64_a53"

log() {
    printf '%s\n' "==> $*"
}

warn() {
    printf '%s\n' "[WARN] $*" >&2
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

usage() {
    cat <<EOF
用法:
  sh hp25.sh --all
  sh hp25.sh --arch x86_64

环境变量:
  OPENWRT_RELEASE=snapshots
  OUT_DIR=dist/homeproxy-run
EOF
}

download_file() {
    url="$1"
    output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$output" && return 0
        curl -kfsSL --retry 2 --connect-timeout 20 "$url" -o "$output" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url" && return 0
        wget --no-check-certificate -qO "$output" "$url" && return 0
    fi
    return 1
}

source_arch_for() {
    case "$1" in
        x86_64) printf '%s\n' "x86_64" ;;
        aarch64_generic) printf '%s\n' "aarch64_generic" ;;
        aarch64_a53) printf '%s\n' "aarch64_cortex-a53" ;;
        aarch64_a72) printf '%s\n' "aarch64_cortex-a72" ;;
        *) die "不支持的架构: $1" ;;
    esac
}

# 从 ImmortalWrt APK 索引下载指定的 pkg
download_apk_from_immortalwrt() {
    source_arch="$1"
    repo="$2"      # luci 或 packages
    keyword="$3"   # 包名称前缀
    outdir="$4"

    index_file="$WORK_ROOT/APKINDEX-${source_arch}-${repo}.tar.gz"
    extract_dir="$WORK_ROOT/index-${source_arch}-${repo}"

    mkdir -p "$extract_dir"
    log "正在获取 $repo 仓库的 APKINDEX..."
    
    # 依次尝试 PKU 镜像与官方源
    download_success=0
    for base_domain in \
        "https://mirrors.pku.edu.cn/immortalwrt" \
        "https://downloads.immortalwrt.org"
    do
        base_url="${base_domain}/snapshots/packages/${source_arch}/${repo}"
        if download_file "${base_url}/APKINDEX.tar.gz" "$index_file"; then
            download_success=1
            break
        fi
    done

    if [ "$download_success" -ne 1 ]; then
        die "无法获取 ${source_arch}/${repo} 的 APKINDEX.tar.gz"
    fi

    tar -zxf "$index_file" -C "$extract_dir"

    # 在 APKINDEX 中查找精准包名
    pkg_name=$(awk -v kw="$keyword" '
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

    if [ -z "$pkg_name" ]; then
        die "在 $repo 仓库中未能找到匹配包: $keyword"
    fi

    log "找到并下载: $pkg_name"
    download_file "${base_url}/${pkg_name}" "${outdir}/${pkg_name}" || die "下载失败: $pkg_name"
}

build_one() {
    label_arch="$1"
    source_arch="$(source_arch_for "$label_arch")"
    apk_dir="$OUT_DIR/apks/$label_arch"
    run_dir="$OUT_DIR/run"

    rm -rf "$apk_dir"
    mkdir -p "$apk_dir" "$run_dir"

    log "开始下载 HomeProxy 依赖包: $label_arch ($source_arch)"

    # 从 ImmortalWrt 官方/镜像 APK 源下载 HomeProxy 组件与核心 sing-box
    download_apk_from_immortalwrt "$source_arch" "luci"     "luci-app-homeproxy"        "$apk_dir"
    download_apk_from_immortalwrt "$source_arch" "luci"     "luci-i18n-homeproxy-zh-cn" "$apk_dir"
    download_apk_from_immortalwrt "$source_arch" "packages" "sing-box"                  "$apk_dir"

    hp_version=$(ls "$apk_dir"/luci-app-homeproxy-*.apk 2>/dev/null | head -n1 | sed -n 's/.*luci-app-homeproxy-\([0-9][0-9.]*\).*/\1/p' || echo "unknown")

    # 创建适用于 OpenWrt 25.12 (apk 包管理器) 的 install.sh
    cat > "$apk_dir/install.sh" <<'EOF'
#!/bin/sh
set -e
apk update
apk add --allow-untrusted *.apk
echo "HomeProxy 安装完成！"
EOF
    chmod +x "$apk_dir/install.sh"

    # 生成自解压 .run 安装包
    package_name="25.12-HomeProxy_${hp_version}_${label_arch}.run"
    run_file="$run_dir/$package_name"

    if command -v makeself >/dev/null 2>&1; then
        makeself --notemp "$apk_dir" "$run_file" "HomeProxy ${hp_version} for ${label_arch}" ./install.sh
        log "生成 .run 文件: $run_file"
    else
        log "未找到 makeself，仅保留 APK"
    fi

    log "架构 $label_arch 处理完成 (版本: $hp_version)"
}

main() {
    need_cmd grep sed awk basename ls tar

    mkdir -p "$WORK_ROOT"
    trap 'rm -rf "$WORK_ROOT" 2>/dev/null || true' EXIT INT TERM

    arches=""
    [ "$#" -eq 0 ] && { usage; exit 0; }

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --all) arches="$DEFAULT_ARCHES"; shift ;;
            --arch)
                [ "$#" -ge 2 ] || die "--arch 需要参数"
                arches="$arches $2"
                shift 2
                ;;
            --help|-h) usage; exit 0 ;;
            *) die "未知参数: $1" ;;
        esac
    done

    [ -n "$arches" ] || die "请指定 --all 或 --arch"

    for arch in $arches; do
        build_one "$arch"
    done

    log "全部完成！APK 在 $OUT_DIR/apks/，.run 在 $OUT_DIR/run/"
}

main "$@"
