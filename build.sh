#!/usr/bin/env bash
# Zen applications build script (macOS/Linux)
# Responsibilities:
#   - Build zen_desktop (Go desktop app) and zen_mobile (Android APK)
#   - Package artifacts into applications/dist
#   - Clean intermediate dist artifacts (helper, html, wasm) after each build
#   - all mode: clean intermediates only after ALL builds complete

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-all}"
PROFILE="${2:-release}"
QUIET="${3:-}"

# ==================== Colors & Logging ====================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_step() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "  $1"
    echo -e "${BLUE}============================================================${NC}"
}

# ==================== Help & Validation ====================

show_help() {
    echo ""
    echo "Usage: ./applications/build.sh [MODE] [PROFILE]"
    echo ""
    echo "MODE (default: all):"
    echo "  desktop  Build zen_desktop app only"
    echo "  apk      Build Android APK only"
    echo "  all      Build both desktop and apk"
    echo "  clean    Clean all build artifacts"
    echo "  help     Show this help"
    echo ""
    echo "PROFILE (default: release):"
    echo "  release  Release build (optimized)"
    echo "  debug    Debug build (with logging)"
    echo ""
    echo "Notes:"
    echo "  - No intermediate artifacts are cleaned after build"
    echo "  - Use 'clean' to remove all build artifacts"
    echo ""
    echo "Tool requirements:"
    echo "  desktop: go (https://go.dev/dl/)"
    echo "  apk: bash, java (JDK 17+), android-sdk (https://developer.android.com/studio)"
}

case "$MODE" in
    desktop|apk|all|clean|help|-h|--help) ;;
    *)
        log_error "Unknown mode: $MODE"
        echo
        show_help
        exit 1
        ;;
esac

if [[ "$MODE" == "help" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ "$PROFILE" != "debug" && "$PROFILE" != "release" ]]; then
    log_error "Unknown profile: $PROFILE (expected: debug or release)"
    echo
    show_help
    exit 1
fi

# Detect Android signing env vars (reporting only — we do not load any
# .env.android or act on these values). The zen_plugin coordinator is
# responsible for setting them; standalone users must export them in
# their shell or source their own .env.android.
report_android_env() {
    if [[ "$PROFILE" != "release" ]]; then
        return 0
    fi
    if [[ "$MODE" != "apk" && "$MODE" != "all" ]]; then
        return 0
    fi
    local vars=(
        ZEN_ANDROID_STORE_FILE
        ZEN_ANDROID_STORE_PASSWORD
        ZEN_ANDROID_KEY_ALIAS
        ZEN_ANDROID_KEY_PASSWORD
    )
    local missing=()
    for v in "${vars[@]}"; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Android signing env vars not set: ${missing[*]}"
        log_warn "Release APK will be unsigned. Set them in your shell (or"
        log_warn "source a .env.android you provisioned) to enable signing."
    else
        log_info "Android signing env vars: present (STORE_FILE=$ZEN_ANDROID_STORE_FILE, ALIAS=$ZEN_ANDROID_KEY_ALIAS)"
    fi
}
report_android_env

# ==================== Constants ====================

DIST_ROOT="$SCRIPT_DIR/dist"
DOCS_DIR="$ROOT_DIR/docs"
DESKTOP_APP_DIR="$SCRIPT_DIR/zen_desktop/app"
DESKTOP_CORE_WEB_DIR="$SCRIPT_DIR/HQChart"
ANDROID_DIR="$SCRIPT_DIR/android"
ANDROID_WEB_DIR="$ANDROID_DIR/web"
TARGET_WASM="wasm32-unknown-unknown"
TARGET_X86_64="x86_64-pc-windows-msvc"

UI_VERSION="1.4.3"
UI_VERSION_FULL="V1.4.3"

# ==================== Utility Functions ====================

detect_platform() {
    local os_type
    local arch
    os_type="$(uname)"
    arch="$(uname -m)"

    case "$os_type" in
        Darwin)
            [ "$arch" = "arm64" ] && arch="aarch64"
            echo "${arch}-apple-darwin"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "${arch}-pc-windows-msvc"
            ;;
        Linux)
            echo "${arch}-unknown-linux-gnu"
            ;;
        *)
            echo "${arch}-unknown-${os_type}"
            ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

NATIVE_TARGET="$(detect_platform)"
OS_TYPE="$(uname)"

helper_name_for_target() {
    if [[ "$1" == *windows* ]]; then
        echo "zen_auth_helper.exe"
    else
        echo "zen_auth_helper"
    fi
}

desktop_output_dir() {
    echo "$DIST_ROOT/$1/$PROFILE/zen_desktop"
}

desktop_binary_name() {
    if [[ "$1" == *windows* ]]; then
        echo "zen_desktop.exe"
    else
        echo "zen_desktop"
    fi
}

# ==================== Cleanup Functions ====================

safe_clean_dir() {
    local dir="$1"
    local tmp_backup
    local has_license=0
    local has_watchlist=0

    mkdir -p "$dir"
    tmp_backup="$(mktemp -d /tmp/zen_application_preserve.XXXXXX)"

    [ -f "$dir/zen_license.key" ] && cp "$dir/zen_license.key" "$tmp_backup/" && has_license=1
    [ -f "$dir/zen_watchlist.json" ] && cp "$dir/zen_watchlist.json" "$tmp_backup/" && has_watchlist=1

    rm -rf "$dir"
    mkdir -p "$dir"

    [ $has_license -eq 1 ] && cp "$tmp_backup/zen_license.key" "$dir/"
    [ $has_watchlist -eq 1 ] && cp "$tmp_backup/zen_watchlist.json" "$dir/"
    rm -rf "$tmp_backup"
}

cleanup_desktop_staging() {
    rm -rf "$DESKTOP_APP_DIR/jscommon" "$DESKTOP_APP_DIR/pkg"
    mkdir -p "$DESKTOP_APP_DIR/jscommon" "$DESKTOP_APP_DIR/pkg"
    touch "$DESKTOP_APP_DIR/jscommon/placeholder.txt" "$DESKTOP_APP_DIR/pkg/placeholder.txt"
    rm -f \
        "$DESKTOP_APP_DIR/ZenHQChartCompat.js" \
        "$DESKTOP_APP_DIR/ZenChartDraw.js" \
        "$DESKTOP_APP_DIR/license_agreement.html" \
        "$DESKTOP_APP_DIR/license_agreement.js" \
        "$DESKTOP_APP_DIR/manual.html" \
        "$DESKTOP_APP_DIR/zen_auth_helper" \
        "$DESKTOP_APP_DIR/zen_auth_helper.exe"
}

# ==================== Tool Check ====================

check_desktop_tools() {
    if ! command_exists go; then
        log_error "Go is not installed."
        echo ""
        echo "To build zen_desktop, please install Go:"
        echo "  macOS/Linux: https://go.dev/dl/"
        echo "  Windows:      https://go.dev/dl/"
        echo "  Or: brew install go (macOS)"
        echo "              choco install golang (Windows with Chocolatey)"
        exit 1
    fi
    log_info "Go found: $(go version | head -1)"
}

check_apk_tools() {
    local missing=()

    if ! command_exists bash; then
        missing+=("bash")
    fi

    if ! command_exists java; then
        missing+=("java (JDK 17+)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools for APK build:"
        for tool in "${missing[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "To build Android APK, please install:"
        echo "  macOS: brew install openjdk@17 android-sdk"
        echo "  Linux: sudo apt install openjdk-17-jdk android-sdk (Debian/Ubuntu)"
        echo "         sudo dnf install java-17-openjdk (Fedora/RHEL)"
        echo "  Windows: Install Android Studio https://developer.android.com/studio"
        exit 1
    fi

    local java_version=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([^"]+)".*/\1/' | cut -d. -f1)
    if [ -z "$java_version" ] || [ "$java_version" -lt 17 ]; then
        log_error "JDK 17+ is required for Android builds. Found JDK $java_version"
        echo "  macOS: brew install openjdk@17"
        echo "  Linux: sudo apt install openjdk-17-jdk"
        echo "  Windows: Download from https://adoptium.net/"
        exit 1
    fi

    log_info "Java found: $(java -version 2>&1 | head -1)"
}

# ==================== Desktop Build ====================

prepare_desktop_staging() {
    local desktop_target="$NATIVE_TARGET"
    local wasm_src="$DIST_ROOT/$TARGET_WASM/$PROFILE/pkg"

    if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]]; then
        desktop_target="$TARGET_X86_64"
    fi

    if [ ! -e "$wasm_src" ]; then
        log_error "Missing WASM package in $wasm_src"
        log_error "Please place the pre-built WASM package in applications/dist/wasm32-unknown-unknown/$PROFILE/pkg/"
        exit 1
    fi
    if [ ! -e "$DIST_ROOT/common/license_agreement.html" ]; then
        log_error "Missing license HTML in $DIST_ROOT/common/license_agreement.html"
        log_error "Please place the pre-built license files in applications/dist/common/"
        exit 1
    fi
    if [ ! -e "$DIST_ROOT/common/license_agreement.js" ]; then
        log_error "Missing license JS in $DIST_ROOT/common/license_agreement.js"
        log_error "Please place the pre-built license files in applications/dist/common/"
        exit 1
    fi

    cleanup_desktop_staging
    rm -rf "$DESKTOP_APP_DIR/jscommon" "$DESKTOP_APP_DIR/pkg"

    log_info "Packing closed-source deps: helper ($desktop_target), wasm ($TARGET_WASM), html"
    cp -R "$DESKTOP_CORE_WEB_DIR/jscommon" "$DESKTOP_APP_DIR/jscommon"
    rm -rf \
        "$DESKTOP_APP_DIR/jscommon/umychart.testdata" \
        "$DESKTOP_APP_DIR/jscommon/umychart.testdata.js" \
        "$DESKTOP_APP_DIR/jscommon/umychart.NetworkFilterTest.js" \
        "$DESKTOP_APP_DIR/jscommon/umychart.regressiontest.js"
    cp "$DESKTOP_CORE_WEB_DIR/ZenHQChartCompat.js" "$DESKTOP_APP_DIR/"
    cp "$DESKTOP_CORE_WEB_DIR/ZenChartDraw.js" "$DESKTOP_APP_DIR/"
    cp -R "$wasm_src" "$DESKTOP_APP_DIR/pkg"
    cp "$DIST_ROOT/common/license_agreement.html" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/license_agreement.js" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/manual.html" "$DESKTOP_APP_DIR/"
}

build_desktop() {
    local desktop_target="$NATIVE_TARGET"
    local out_dir
    local output_name
    local base_flags=""
    local ldflags="-s -w -X main._internalFlag=0 $base_flags"
    local build_failed=0

    if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]]; then
        desktop_target="$TARGET_X86_64"
    fi

    print_step "Building zen_desktop ($PROFILE) for $desktop_target"
    check_desktop_tools

    out_dir="$(desktop_output_dir "$desktop_target")"
    safe_clean_dir "$out_dir"
    output_name="$(desktop_binary_name "$desktop_target")"
    [ "$PROFILE" = "debug" ] && ldflags="-X main._internalFlag=1 $base_flags"

    # Release 模式下 Windows 隐藏控制台窗口（-H windowsgui）
    if [ "$PROFILE" = "release" ]; then
        if [[ "$desktop_target" == *"windows"* ]]; then
            ldflags="$ldflags -H windowsgui"
        fi
    fi

    prepare_desktop_staging

    # Copy helper BEFORE Go build (Go embed needs file present at compile time)
    local helper_name
    helper_name="$(helper_name_for_target "$desktop_target")"
    local helper_src="$DIST_ROOT/$desktop_target/$PROFILE/$helper_name"
    if [ ! -e "$helper_src" ]; then
        log_error "Missing helper binary. Please run src/build.sh all first."
        cleanup_desktop_staging
        exit 1
    fi
    cp "$helper_src" "$DESKTOP_APP_DIR/$helper_name"

    # Helper is already stripped by src/build.sh (build_helper_for_target).
    # Calculate SHA-256 of the (pre-stripped) helper and inject into Go binary
    # via -ldflags. Runtime verifyHelperIntegrity compares the on-disk helper
    # against this value, blocking "swap helper at runtime" attacks.
    local helper_sha256=""
    if [ "$PROFILE" = "release" ]; then
        if command_exists sha256sum; then
            helper_sha256="$(sha256sum "$DESKTOP_APP_DIR/$helper_name" | awk '{print $1}')"
        elif command_exists shasum; then
            helper_sha256="$(shasum -a 256 "$DESKTOP_APP_DIR/$helper_name" | awk '{print $1}')"
        else
            log_warn "未找到 sha256sum / shasum, 跳过 helper 完整性校验注入(不推荐)."
        fi
        if [ -n "$helper_sha256" ]; then
            ldflags="$ldflags -X main.expectedHelperSHA256=$helper_sha256"
            log_info "helper SHA-256: $helper_sha256"
        fi
    fi

    cp "$DIST_ROOT/common/license_agreement.html" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/license_agreement.js" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/manual.html" "$DESKTOP_APP_DIR/"
    cp "$DESKTOP_CORE_WEB_DIR/ZenChartDraw.js" "$DESKTOP_APP_DIR/"
    cp "$DESKTOP_CORE_WEB_DIR/ZenHQChartCompat.js" "$DESKTOP_APP_DIR/"

    if ! (
        cd "$DESKTOP_APP_DIR"
        go build -buildvcs=false -ldflags "$ldflags" -o "$out_dir/$output_name" .
    ); then
        log_error "Go desktop build failed"
        build_failed=1
    fi

    cleanup_desktop_staging

    if [ $build_failed -eq 1 ]; then
        exit 1
    fi

    log_info "Desktop:  $out_dir/$output_name"
}

# ==================== Android Build ====================

build_android() {
    local output_dir="$DIST_ROOT/aarch64-linux-android/$PROFILE/zen_mobile"

    print_step "Building zen_mobile ($PROFILE)"
    check_apk_tools
    log_info "Closed-source deps: aar (aarch64-linux-android), wasm ($TARGET_WASM), html"

    if [ "$PROFILE" = "release" ]; then
        if [ -z "${ZEN_ANDROID_STORE_FILE:-}" ] || [ -z "${ZEN_ANDROID_STORE_PASSWORD:-}" ] \
            || [ -z "${ZEN_ANDROID_KEY_ALIAS:-}" ] || [ -z "${ZEN_ANDROID_KEY_PASSWORD:-}" ]; then
            log_warn "APK build skipped due to missing signing configuration."
            return 0
        fi
    fi

    if ! bash "$ANDROID_DIR/build_android.sh" "$PROFILE" "$output_dir"; then
        exit 1
    fi

    log_info "Android:  $output_dir/zen_mobile_universal.apk"
}

# ==================== Clean Mode ====================

do_clean() {
    print_step "Cleaning Application Artifacts"
    if [ -d "$DIST_ROOT" ]; then
        for target_dir in "$DIST_ROOT"/*; do
            [ -d "$target_dir" ] || continue
            rm -rf \
                "$target_dir/release/zen_mobile" \
                "$target_dir/debug/zen_mobile" \
                "$target_dir/release/zen_desktop" \
                "$target_dir/debug/zen_desktop" 2>/dev/null || true
        done
    fi
    # Gradle / Android 中间产物（regenerable，从未入库）
    rm -rf \
        "$ANDROID_DIR/zen_mobile/app/build" \
        "$ANDROID_DIR/zen_mobile/build" \
        "$ANDROID_DIR/zen_mobile/.gradle" \
        "$ANDROID_DIR/zen_mobile/.kotlin" \
        "$ANDROID_DIR/zen_mobile/.idea" 2>/dev/null || true
    cleanup_desktop_staging
    log_info "Application artifacts cleaned."
}

# ==================== Summary ====================

check_and_print() {
    local lbl="$1"
    local pth="$2"
    printf "  %-10s " "$lbl:"
    if [ -f "$pth" ] || [ -d "$pth" ]; then
        echo "$pth"
    else
        echo -e "${RED}[FAILED]${NC}"
    fi
}

show_summary() {
    local desktop_target="$NATIVE_TARGET"
    local desktop_name

    [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]] && desktop_target="$TARGET_X86_64"
    desktop_name="$(desktop_binary_name "$desktop_target")"

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  BUILD SUMMARY (${MODE}, ${PROFILE})"
    echo -e "${CYAN}============================================================${NC}"

    case "$MODE" in
        desktop)
            check_and_print "Desktop" "$(desktop_output_dir "$desktop_target")/$desktop_name"
            ;;
        apk)
            if [ -z "${ZEN_ANDROID_STORE_FILE:-}" ] || [ -z "${ZEN_ANDROID_STORE_PASSWORD:-}" ] \
                || [ -z "${ZEN_ANDROID_KEY_ALIAS:-}" ] || [ -z "${ZEN_ANDROID_KEY_PASSWORD:-}" ]; then
                echo "  Android:  [SKIPPED] Missing signing configuration"
            else
                check_and_print "Android" "$DIST_ROOT/aarch64-linux-android/$PROFILE/zen_mobile/zen_mobile_universal.apk"
            fi
            ;;
        all)
            check_and_print "Desktop" "$(desktop_output_dir "$desktop_target")/$desktop_name"
            if [ -z "${ZEN_ANDROID_STORE_FILE:-}" ] || [ -z "${ZEN_ANDROID_STORE_PASSWORD:-}" ] \
                || [ -z "${ZEN_ANDROID_KEY_ALIAS:-}" ] || [ -z "${ZEN_ANDROID_KEY_PASSWORD:-}" ]; then
                echo "  Android:  [SKIPPED] Missing signing configuration"
            else
                check_and_print "Android" "$DIST_ROOT/aarch64-linux-android/$PROFILE/zen_mobile/zen_mobile_universal.apk"
            fi
            ;;
    esac
    echo -e "${CYAN}============================================================${NC}"
}

# ==================== README Rendering ====================

resize_image_for_readme() {
    local src="$1"
    local dst="$2"
    local width="$3"
    local tmp_dir="$SCRIPT_DIR/_tmp_inline_imgs"

    mkdir -p "$tmp_dir"
    sips -z "$width" "$width" "$src" --out "$tmp_dir/$(basename "$dst")" >/dev/null 2>&1 || {
        cp "$src" "$tmp_dir/$(basename "$dst")"
    }
}

image_to_data_uri() {
    local file="$1"
    local mime
    case "${file##*.}" in
        png) mime="image/png" ;;
        jpg|jpeg) mime="image/jpeg" ;;
        gif) mime="image/gif" ;;
        webp) mime="image/webp" ;;
        *) mime="application/octet-stream" ;;
    esac
    echo "data:$mime;base64,$(base64 -i "$file")"
}

render_readme() {
    local readme_src="$SCRIPT_DIR/README.md"
    local readme_dst="$SCRIPT_DIR/README.html"
    local tmp_dir="$SCRIPT_DIR/_tmp_inline_imgs"

    if [ ! -f "$readme_src" ]; then
        log_warn "README.md not found, skipping readme render"
        return
    fi

    if ! command_exists pandoc; then
        log_warn "pandoc not found, skipping readme render"
        return
    fi

    log_info "Rendering README.md → README.html..."

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    resize_image_for_readme "$SCRIPT_DIR/qrcode/wechat.png" "$tmp_dir/wechat.png" 100
    resize_image_for_readme "$SCRIPT_DIR/qrcode/alipay.png" "$tmp_dir/alipay.png" 100
    resize_image_for_readme "$SCRIPT_DIR/qrcode/qq.png" "$tmp_dir/qq.png" 100

    local wechat_uri alipay_uri qq_uri
    wechat_uri="$(image_to_data_uri "$tmp_dir/wechat.png")"
    alipay_uri="$(image_to_data_uri "$tmp_dir/alipay.png")"
    qq_uri="$(image_to_data_uri "$tmp_dir/qq.png")"

    pandoc -s --self-contained --resource-path="$SCRIPT_DIR:.." --css="$SCRIPT_DIR/README.css" -o "$readme_dst" "$readme_src" 2>/dev/null || {
        log_warn "Failed to render README"
        rm -rf "$tmp_dir"
        return
    }

    perl -pi -e 's|src="qrcode/wechat\.png"|src="'"$wechat_uri"'"|' "$readme_dst"
    perl -pi -e 's|src="qrcode/alipay\.png"|src="'"$alipay_uri"'"|' "$readme_dst"
    perl -pi -e 's|src="qrcode/qq\.png"|src="'"$qq_uri"'"|' "$readme_dst"

    rm -rf "$tmp_dir"
    log_info "README: $readme_dst"
}

# ==================== Main Dispatch ====================

case "$MODE" in
    desktop|apk|all)
        # Always render readme FIRST for any build mode
        # This ensures README.html is fresh when called from root build.sh
        render_readme
        ;;
esac

case "$MODE" in
    desktop)
        build_desktop
        cleanup_desktop_staging
        ;;
    apk)
        build_android
        ;;
    all)
        build_desktop
        cleanup_desktop_staging
        build_android
        ;;
    clean)
        do_clean
        ;;
esac

if [[ "$MODE" != "clean" ]] && [[ "$QUIET" != "1" ]]; then
    show_summary
fi
