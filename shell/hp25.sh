#!/bin/sh
set -eu

SF_PROJECT="openwrt-passwall-build"
SF_BASE="https://sourceforge.net/projects/$SF_PROJECT/files"
OPENWRT_RELEASE="${OPENWRT_RELEASE:-25.12}"
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
  OPENWRT_RELEASE=25.12
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

valid_pkg_file() {
    file="$1"
    [ -s "$file" ] || return 1
    [ "$(wc -c < "$file")" -gt 1024 ] || return 1
    if head -c 512 "$file" 2>/dev/null | tr 'A-Z' 'a-z' | grep -qE '<html|<!doctype|sourceforge'; then
        return 1
    fi
    return 0
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

latest_sf_file() {
    source_arch="$1"
    repo="$2"
    regex="$3"
    tmp="$WORK_ROOT/sf-$source_arch-$repo.txt"
    package_dir="releases/packages-$OPENWRT_RELEASE/$source_arch"
    rss_url="https://sourceforge.net/projects/$SF_PROJECT/rss?path=/$package_dir/$repo"
    folder_url="$SF_BASE/$package_dir/$repo/"

    if download_file "$rss_url" "$tmp"; then
        name="$(grep -oE '[A-Za-z0-9._+-]+\.apk' "$tmp" | grep -E "$regex" | head -n1 || true)"
        [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
    fi

    if download_file "$folder_url" "$tmp"; then
        name="$(grep -oE '[A-Za-z0-9._+-]+\.apk' "$tmp" | grep -E "$regex" | head -n1 || true)"
        [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
    fi
    return 1
}

download_sf_package() {
    source_arch="$1"; repo="$2"; filename="$3"; outdir="$4"
    package_dir="releases/packages-$OPENWRT_RELEASE/$source_arch"
    output="$outdir/$filename"

    for url in \
        "https://master.dl.sourceforge.net/project/$SF_PROJECT/$package_dir/$repo/$filename" \
        "https://downloads.sourceforge.net/project/$SF_PROJECT/$package_dir/$repo/$filename" \
        "https://sourceforge.net/projects/$SF_PROJECT/files/$package_dir/$repo/$filename/download"
    do
        rm -f "$output"
        if download_file "$url" "$output" && valid_pkg_file "$output"; then
            return 0
        fi
        warn "下载失败，尝试下一个源: $filename"
    done
    return 1
}

download_target() {
    title="$1"; source_arch="$2"; repo="$3"; regex="$4"; outdir="$5"
    filename="$(latest_sf_file "$source_arch" "$repo" "$regex" || true)"
    [ -n "$filename" ] || die "没有找到 $title"
    log "下载: $filename"
    download_sf_package "$source_arch" "$repo" "$filename" "$outdir" || die "下载失败: $filename"
}

build_one() {
    label_arch="$1"
    source_arch="$(source_arch_for "$label_arch")"
    apk_dir="$OUT_DIR/apks/$label_arch"
    run_dir="$OUT_DIR/run"

    rm -rf "$apk_dir"
    mkdir -p "$apk_dir" "$run_dir"

    log "开始下载 HomeProxy 依赖包: $label_arch ($source_arch)"

    # 从 25.12 对应的 apk 仓库中拉取 HomeProxy 及核心依赖 sing-box
    download_target "luci-app-homeproxy"        "$source_arch" "passwall_luci"     '^luci-app-homeproxy-[0-9].*\.apk$'        "$apk_dir"
    download_target "luci-i18n-homeproxy-zh-cn" "$source_arch" "passwall_luci"     '^luci-i18n-homeproxy-zh-cn-[0-9].*\.apk$' "$apk_dir"
    download_target "sing-box"                  "$source_arch" "passwall_packages" '^sing-box-[0-9].*\.apk$'                  "$apk_dir"

    hp_version=$(ls "$apk_dir"/luci-app-homeproxy-*.apk 2>/dev/null | head -n1 | sed -n 's/.*luci-app-homeproxy-\([0-9][0-9.]*\).*/\1/p' || echo "unknown")

    # 创建适用于 OpenWrt 25.12 (apk 包管理器) 的 install.sh
    cat > "$apk_dir/install.sh" <<'EOF'
#!/bin/sh
set -e
apk update
apk add --allow-untrusted *.apk
echo "HomeProxy 25.12 安装完成！"
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
    need_cmd grep sed awk basename ls

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
