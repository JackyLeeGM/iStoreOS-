#!/bin/sh
set -eu

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

# 从 ImmortalWrt 镜像源或 GitHub 最新 Release 抓取包
download_target_apk() {
    keyword="$1"
    source_arch="$2"
    outdir="$3"

    log "正在寻找 $keyword ($source_arch)..."

    # 方式 1：尝试从 ImmortalWrt 官方 Snapshots API / Mirror 的 index 中匹配
    index_file="$WORK_ROOT/index-${source_arch}.html"
    
    # 候选 URL 架构列表
    candidate_urls="
https://downloads.immortalwrt.org/snapshots/packages/${source_arch}/luci/
https://downloads.immortalwrt.org/snapshots/packages/${source_arch}/packages/
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/${source_arch}/luci/
https://mirrors.pku.edu.cn/immortalwrt/snapshots/packages/${source_arch}/packages/
https://api.github.com/repos/immortalwrt/homeproxy/releases/latest
"

    for base_url in $candidate_urls; do
        if echo "$base_url" | grep -q "github.com"; then
            # GitHub Releases 保底
            release_json="$WORK_ROOT/gh-release.json"
            if download_file "$base_url" "$release_json"; then
                apk_url=$(grep -oE 'https://[^\"]+' "$release_json" | grep -E "${keyword}.*\.apk$" | head -n1 || true)
                if [ -n "$apk_url" ]; then
                    filename=$(basename "$apk_url")
                    log "从 GitHub Releases 找到: $filename"
                    if download_file "$apk_url" "${outdir}/${filename}"; then
                        return 0
                    fi
                fi
            fi
        else
            # 尝试直接抓取索引/列表
            idx_url="${base_url}APKINDEX.tar.gz"
            tar_file="$WORK_ROOT/APKINDEX-${source_arch}-$$.tar.gz"
            
            if download_file "$idx_url" "$tar_file"; then
                extract_dir="$WORK_ROOT/ext-${source_arch}-$$"
                mkdir -p "$extract_dir"
                tar -zxf "$tar_file" -C "$extract_dir" 2>/dev/null || true
                
                if [ -f "$extract_dir/APKINDEX" ]; then
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

                    if [ -n "$pkg_name" ]; then
                        log "成功从源 $base_url 找到包: $pkg_name"
                        if download_file "${base_url}${pkg_name}" "${outdir}/${pkg_name}"; then
                            return 0
                        fi
                    fi
                fi
            fi
        fi
    done

    die "无法找到或下载 $keyword"
}

build_one() {
    label_arch="$1"
    source_arch="$(source_arch_for "$label_arch")"
    apk_dir="$OUT_DIR/apks/$label_arch"
    run_dir="$OUT_DIR/run"

    rm -rf "$apk_dir"
    mkdir -p "$apk_dir" "$run_dir"

    log "开始下载 HomeProxy 依赖包: $label_arch ($source_arch)"

    # 依次拉取应用及核心依赖包
    download_target_apk "luci-app-homeproxy"        "$source_arch" "$apk_dir"
    download_target_apk "luci-i18n-homeproxy-zh-cn" "$source_arch" "$apk_dir"
    download_target_apk "sing-box"                  "$source_arch" "$apk_dir"

    hp_version=$(ls "$apk_dir"/luci-app-homeproxy-*.apk 2>/dev/null | head -n1 | sed -n 's/.*luci-app-homeproxy-\([0-9][0-9.]*\).*/\1/p' || echo "1.0.0")

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
