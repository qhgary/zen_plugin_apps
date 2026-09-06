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

# Security audit: release builds use -trimpath to strip absolute
# build-machine paths from binaries (panic stacks, runtime.Caller).
# Does not affect logging (Lshortfile only prints the base filename).
GO_TRIMPATH=""
[ "$PROFILE" = "release" ] && GO_TRIMPATH="-trimpath"

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
    echo "  replay   Build zen_replay app only"
    echo "  apk      Build Android APK only"
    echo "  all      Build desktop + replay + apk"
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
    desktop|replay|apk|all|clean|help|-h|--help) ;;
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
REPLAY_APP_DIR="$SCRIPT_DIR/zen_replay/app"
ANDROID_DIR="$SCRIPT_DIR/android"
ANDROID_WEB_DIR="$ANDROID_DIR/zen_mobile/frontend"
TARGET_WASM="wasm32-unknown-unknown"
TARGET_X86_64="x86_64-pc-windows-msvc"
# HTML/document file names
MANUAL_HTML="manual.html"
LIC_HTML="license_agreement.html"
LIC_JS="license_agreement.js"
ZEN_ERR_JS="zen_error_codes.js"
LIC_CSS="license_agreement_style.css"
WASM_LIB_NAME="tdx_zen_bg.wasm"
WASM_JS_NAME="tdx_zen.js"
README_MD="README.md"
README_HTML="README.html"
README_CSS="README.css"
MANUAL_HTML_ZIP="用户手册.html"

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

replay_output_dir() {
    # replay 二进制输出到独立的 zen_replay 目录
    echo "$DIST_ROOT/$1/$PROFILE/zen_replay"
}

replay_binary_name() {
    if [[ "$1" == *windows* ]]; then
        echo "zen_replay.exe"
    else
        echo "zen_replay"
    fi
}

# ==================== Incremental Build Check ====================
# Check if output needs rebuilding based on source files/dirs.
# Directories are scanned recursively (excluding dot-files).
# Usage: need_rebuild [--shallow] [--exclude "dir1" --exclude "dir2"] "output" "src1" "src2" ...
# Returns: 0 = need rebuild, 1 = can skip
need_rebuild() {
    local shallow=0
    local excludes=()
    while [[ "$1" == --* ]]; do
        case "$1" in
            --shallow) shallow=1 ;;
            --exclude) shift; excludes+=("${1%/}") ;;
            *) break ;;
        esac
        shift
    done
    local output="$1"
    shift
    [[ ! -e "$output" ]] && return 0
    local src
    for src in "$@"; do
        if [[ -d "$src" ]]; then
            local find_opts=(-type f -not -name '.*')
            [[ "$shallow" -eq 1 ]] && find_opts=(-maxdepth 1 "${find_opts[@]}")
            local ex
            for ex in "${excludes[@]}"; do
                find_opts+=(-not -path "$ex/*")
            done
            if find "$src" "${find_opts[@]}" -newer "$output" -print -quit 2>/dev/null | grep -q .; then
                return 0
            fi
        elif [[ -f "$src" ]] && [[ "$src" -nt "$output" ]]; then
            return 0
        elif [[ ! -e "$src" ]]; then
            # Source file/dir missing → force rebuild (matches Batch behavior)
            return 0
        fi
    done
    return 1
}

cleanup_replay_staging() {
# 清理 zen_replay/app/ 下的构建产物（从 dist/common/ 复制的临时文件）。
# 注意：这些文件在 .gitignore 中已排除，不应被 git 跟踪。
# 如果 git 报 deleted，说明文件被误提交了，需要 git rm --cached。
rm -rf "$REPLAY_APP_DIR/pkg"
mkdir -p "$REPLAY_APP_DIR/pkg"
touch "$REPLAY_APP_DIR/pkg/placeholder.txt"
rm -f \
"$REPLAY_APP_DIR/zen_auth_helper" \
"$REPLAY_APP_DIR/zen_auth_helper.exe" \
"$REPLAY_APP_DIR/$LIC_HTML" \
"$REPLAY_APP_DIR/$LIC_JS" \
"$REPLAY_APP_DIR/$ZEN_ERR_JS"
# Recreate empty placeholders for go:embed IDE compatibility
# (build script overwrites with real files before go build; cleanup restores empties)
touch \
"$REPLAY_APP_DIR/$LIC_HTML" \
"$REPLAY_APP_DIR/$LIC_JS" \
"$REPLAY_APP_DIR/$ZEN_ERR_JS" \
"$REPLAY_APP_DIR/zen_auth_helper"
# Restore original replay.html if obfuscation backup exists
restore_replay_html
# 删除本地手动 go build 残留的游离二进制（非构建脚本产物）
rm -f "$REPLAY_APP_DIR/zen_replay" "$REPLAY_APP_DIR/zen_replay.exe" 2>/dev/null || true
}

# ==================== Replay HTML JS Obfuscation ====================
# Obfuscate inline JavaScript in replay.html for release builds.
# Uses javascript-obfuscator (same tool as WASM JS glue code obfuscation).
# Backup is created before obfuscation and restored after Go build.
obfuscate_replay_html() {
    local html_file="$REPLAY_APP_DIR/replay.html"
    if [ ! -f "$html_file" ]; then
        log_error "replay.html not found for obfuscation"
        return 1
    fi

    # Only obfuscate in release mode
    if [ "$PROFILE" != "release" ]; then
        return 0
    fi

    # Find javascript-obfuscator module
    local obf_module
    for p in "$(npm root -g 2>/dev/null)/javascript-obfuscator" \
              "/usr/local/lib/node_modules/javascript-obfuscator" \
              "/opt/homebrew/lib/node_modules/javascript-obfuscator" \
              "$HOME/.npm/lib/node_modules/javascript-obfuscator"; do
        if [ -d "$p" ]; then
            obf_module="$p"
            break
        fi
    done

    if [ -z "$obf_module" ]; then
        log_warn "javascript-obfuscator not found, skipping replay.html JS obfuscation"
        log_warn "Install with: npm install -g javascript-obfuscator"
        return 0
    fi

    # Backup original
    cp "$html_file" "${html_file}.bak"

    local obf_script="/tmp/zen_replay_obf_$$.js"
    cat > "$obf_script" << 'SCRIPT'
const fs = require('fs');
const { obfuscate } = require(process.argv[3]);
const htmlFile = process.argv[2];
const html = fs.readFileSync(htmlFile, 'utf8');
const scriptRegex = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let match;
let modified = html;
let count = 0;
while ((match = scriptRegex.exec(html)) !== null) {
    const fullMatch = match[0];
    const jsContent = match[1];
    if (!jsContent.trim()) continue;
    const result = obfuscate(jsContent, {compact:true, controlFlowFlattening:true, controlFlowFlatteningThreshold:0.75, deadCodeInjection:true, deadCodeInjectionThreshold:0.4, stringArray:true, stringArrayThreshold:0.8, unicodeEscapeSequence:true, selfDefending:true});
    const newScript = fullMatch.replace(jsContent, result.getObfuscatedCode());
    modified = modified.replace(fullMatch, newScript);
    count++;
}
fs.writeFileSync(htmlFile, modified);
console.log('Obfuscated ' + count + ' inline script(s) in ' + htmlFile);
SCRIPT

    node "$obf_script" "$html_file" "$obf_module"
    local exit_code=$?
    rm -f "$obf_script"

    if [ $exit_code -ne 0 ]; then
        log_warn "replay.html JS obfuscation failed, restoring original"
        cp "${html_file}.bak" "$html_file"
        return 0
    fi

    log_info "replay.html JS obfuscation complete"
    return 0
}

restore_replay_html() {
    local html_file="$REPLAY_APP_DIR/replay.html"
    if [ -f "${html_file}.bak" ]; then
        cp "${html_file}.bak" "$html_file"
        rm -f "${html_file}.bak"
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
        "$DESKTOP_APP_DIR/$LIC_HTML" \
        "$DESKTOP_APP_DIR/$LIC_JS" \
        "$DESKTOP_APP_DIR/$ZEN_ERR_JS" \
        "$DESKTOP_APP_DIR/$MANUAL_HTML" \
        "$DESKTOP_APP_DIR/zen_auth_helper" \
        "$DESKTOP_APP_DIR/zen_auth_helper.exe"
    # Recreate empty placeholders for go:embed IDE compatibility
    # (build script overwrites with real files before go build; cleanup restores empties)
    touch \
        "$DESKTOP_APP_DIR/ZenChartDraw.js" \
        "$DESKTOP_APP_DIR/ZenHQChartCompat.js" \
        "$DESKTOP_APP_DIR/$LIC_HTML" \
        "$DESKTOP_APP_DIR/$LIC_JS" \
        "$DESKTOP_APP_DIR/$ZEN_ERR_JS" \
        "$DESKTOP_APP_DIR/zen_auth_helper"
    # 删除本地手动 go build 残留的游离二进制（非构建脚本产物）
    rm -f "$DESKTOP_APP_DIR/zen_desktop" "$DESKTOP_APP_DIR/zen_desktop.exe" 2>/dev/null || true
}

prepare_replay_staging() {
    local replay_target="$NATIVE_TARGET"
    local wasm_src="$DIST_ROOT/$TARGET_WASM/$PROFILE/pkg"

    if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]]; then
        replay_target="$TARGET_X86_64"
    fi

    if [ ! -e "$wasm_src" ]; then
        log_error "Missing WASM package in $wasm_src"
        log_error "Please run src/build.sh wasm first."
        exit 1
    fi

    cleanup_replay_staging
    rm -rf "$REPLAY_APP_DIR/pkg"

    log_info "Packing closed-source deps: helper ($replay_target), wasm ($TARGET_WASM)"
    cp -R "$wasm_src" "$REPLAY_APP_DIR/pkg"
}

build_replay() {
    local replay_target="$NATIVE_TARGET"
    local out_dir
    local output_name
    local base_flags=""
    local ldflags="-s -w -X main._internalFlag=0 $base_flags"
    local build_failed=0

    if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]]; then
        replay_target="$TARGET_X86_64"
    fi

    print_step "Building zen_replay ($PROFILE) for $replay_target"
    check_desktop_tools

    out_dir="$(replay_output_dir "$replay_target")"
    mkdir -p "$out_dir"
    output_name="$(replay_binary_name "$replay_target")"

    # Incremental build: skip if nothing changed since last build.
    # Use --shallow for app dir (has staging subdir pkg/).
    # Desktop/Replay embed Helper+WASM via go:embed; check union of their source dirs.
    # docs/ and LICENSE.md are already checked by the HTML build step.
    if ! need_rebuild --shallow "$out_dir/$output_name" "$REPLAY_APP_DIR" && \
       ! need_rebuild "$out_dir/$output_name" \
        "$DESKTOP_CORE_WEB_DIR" \
        "$DIST_ROOT/$replay_target/$PROFILE/$(helper_name_for_target "$replay_target")" \
        "$DIST_ROOT/$TARGET_WASM/$PROFILE/pkg/$WASM_LIB_NAME" \
        "$DIST_ROOT/common/$LIC_HTML" \
        "$DIST_ROOT/common/$LIC_JS" \
        "$DIST_ROOT/common/$ZEN_ERR_JS" \
        "$ROOT_DIR/src/auth" \
        "$ROOT_DIR/src/common" \
        "$ROOT_DIR/src/key" \
        "$ROOT_DIR/src/lib.rs" \
        "$ROOT_DIR/src/interfaces/mod.rs" \
        "$ROOT_DIR/src/interfaces/interface_wasm" \
        "$ROOT_DIR/src/indicators" \
        "$ROOT_DIR/src/kline" \
        "$ROOT_DIR/src/market" \
        "$ROOT_DIR/src/movement" \
        "$ROOT_DIR/src/pivot" \
        "$ROOT_DIR/src/segment" \
        "$ROOT_DIR/src/stroke" \
        "$ROOT_DIR/Cargo.toml" \
        "$ROOT_DIR/Cargo.lock"; then
        log_info "Skipping Replay (up-to-date): $out_dir/$output_name"
        return 0
    fi
    [ "$PROFILE" = "debug" ] && ldflags="-X main._internalFlag=1 $base_flags"

    # Release: Windows hidden console window (-H windowsgui)
    if [ "$PROFILE" = "release" ]; then
        if [[ "$replay_target" == *"windows"* ]]; then
            ldflags="$ldflags -H windowsgui"
        fi
    fi

    prepare_replay_staging

    # Copy helper BEFORE Go build (Go embed needs file at compile time)
    local helper_name
    helper_name="$(helper_name_for_target "$replay_target")"
    local helper_src="$DIST_ROOT/$replay_target/$PROFILE/$helper_name"
    if [ ! -e "$helper_src" ]; then
        log_error "Missing helper binary. Please run src/build.sh all first."
        cleanup_replay_staging
        exit 1
    fi
    cp "$helper_src" "$REPLAY_APP_DIR/$helper_name"

    # Copy license agreement files BEFORE Go build (Go embed needs them at compile time)
    cp "$DIST_ROOT/common/$LIC_HTML" "$REPLAY_APP_DIR/"
    cp "$DIST_ROOT/common/$LIC_JS" "$REPLAY_APP_DIR/"
    cp "$DIST_ROOT/common/$ZEN_ERR_JS" "$REPLAY_APP_DIR/"

    # Helper SHA-256 (same as desktop)
    local helper_sha256=""
    if [ "$PROFILE" = "release" ]; then
        if command_exists sha256sum; then
            helper_sha256="$(sha256sum "$REPLAY_APP_DIR/$helper_name" | awk '{print $1}')"
        elif command_exists shasum; then
            helper_sha256="$(shasum -a 256 "$REPLAY_APP_DIR/$helper_name" | awk '{print $1}')"
        else
            log_warn "sha256sum / shasum not found, skipping helper integrity injection."
        fi
        if [ -n "$helper_sha256" ]; then
            ldflags="$ldflags -X main.expectedHelperSHA256=$helper_sha256"
            log_info "helper SHA-256: $helper_sha256"
        fi
    fi

    echo -- Compiling Go replay app...

    # Kill any running zen_replay/zen_replay.exe so go build can overwrite
    # the output file.
    case "$replay_target" in
        *windows*) cmd //c "taskkill /F /IM zen_replay.exe" >/dev/null 2>&1 || true ;;
        *darwin*|*linux*) pkill -f zen_replay >/dev/null 2>&1 || true ;;
    esac

    safe_clean_dir "$(replay_output_dir "$replay_target")"

    # Obfuscate replay.html inline JS (release mode only)
    # Must happen BEFORE Go build so the embedded HTML has obfuscated JS
    obfuscate_replay_html

    if ! (
        cd "$REPLAY_APP_DIR"
        go build -buildvcs=false $GO_TRIMPATH -ldflags "$ldflags" -o "$out_dir/$output_name" .
    ); then
        log_error "Go replay build failed"
        build_failed=1
    fi

    # Restore original replay.html (obfuscated version was embedded in Go binary)
    restore_replay_html

    if [ $build_failed -eq 1 ]; then
        cleanup_replay_staging
        exit 1
    fi

    log_info "Replay:   $out_dir/$output_name"
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

    # Auto-configure GOPROXY for users in China: if GOPROXY is unset or
    # still the default proxy.golang.org, switch to goproxy.cn mirror.
    # Users who set GOPROXY themselves (e.g. a corporate proxy) are respected.
    local current_goproxy
    current_goproxy="$(go env GOPROXY 2>/dev/null)"
    if [[ "$current_goproxy" == "https://proxy.golang.org,direct" ]]; then
        go env -w GOPROXY=https://goproxy.cn,direct
        log_info "GOPROXY auto-set to goproxy.cn (default proxy unreachable)"
    fi
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
    if [ ! -e "$DIST_ROOT/common/$LIC_HTML" ]; then
        log_error "Missing license HTML in $DIST_ROOT/common/$LIC_HTML"
        log_error "Please place the pre-built license files in applications/dist/common/"
        exit 1
    fi
    if [ ! -e "$DIST_ROOT/common/$LIC_JS" ]; then
        log_error "Missing license JS in $DIST_ROOT/common/$LIC_JS"
        log_error "Please place the pre-built license files in applications/dist/common/"
        exit 1
    fi
    if [ ! -e "$DIST_ROOT/common/$ZEN_ERR_JS" ]; then
        log_error "Missing $ZEN_ERR_JS in $DIST_ROOT/common/$ZEN_ERR_JS"
        log_error "Please run src/build.sh html first"
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
    cp "$DIST_ROOT/common/$LIC_HTML" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/$LIC_JS" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/$ZEN_ERR_JS" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/$MANUAL_HTML" "$DESKTOP_APP_DIR/"
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
    output_name="$(desktop_binary_name "$desktop_target")"

    # Incremental build: skip if nothing changed since last build.
    # Use --shallow for app dir (has staging subdirs pkg/ and jscommon/).
    # Desktop/Replay embed Helper+WASM via go:embed; check union of their source dirs.
    # docs/ and LICENSE.md are already checked by the HTML build step.
    if ! need_rebuild --shallow "$out_dir/$output_name" "$DESKTOP_APP_DIR" && \
       ! need_rebuild "$out_dir/$output_name" \
        "$DESKTOP_CORE_WEB_DIR" \
        "$SCRIPT_DIR/zen_desktop/core/go" \
        "$DIST_ROOT/$desktop_target/$PROFILE/$(helper_name_for_target "$desktop_target")" \
        "$DIST_ROOT/$TARGET_WASM/$PROFILE/pkg/$WASM_LIB_NAME" \
        "$DIST_ROOT/common/$LIC_HTML" \
        "$DIST_ROOT/common/$LIC_JS" \
        "$DIST_ROOT/common/$ZEN_ERR_JS" \
        "$DIST_ROOT/common/$MANUAL_HTML" \
        "$ROOT_DIR/src/auth" \
        "$ROOT_DIR/src/common" \
        "$ROOT_DIR/src/key" \
        "$ROOT_DIR/src/lib.rs" \
        "$ROOT_DIR/src/interfaces/mod.rs" \
        "$ROOT_DIR/src/interfaces/interface_wasm" \
        "$ROOT_DIR/src/indicators" \
        "$ROOT_DIR/src/kline" \
        "$ROOT_DIR/src/market" \
        "$ROOT_DIR/src/movement" \
        "$ROOT_DIR/src/pivot" \
        "$ROOT_DIR/src/segment" \
        "$ROOT_DIR/src/stroke" \
        "$ROOT_DIR/Cargo.toml" \
        "$ROOT_DIR/Cargo.lock"; then
        log_info "Skipping Desktop (up-to-date): $out_dir/$output_name"
        return 0
    fi

    echo -- Compiling Go desktop app...

    # Kill any running zen_desktop/zen_desktop.exe so go build can overwrite
    # the output file. On Windows, a running .exe locks the file; on Unix,
    # a running process holds the inode but go build replaces it (rename)
    # which is fine — so the kill is best-effort and silently skipped on
    # platforms without the binary.
    case "$desktop_target" in
        *windows*) cmd //c "taskkill /F /IM zen_desktop.exe" >/dev/null 2>&1 || true ;;
        *darwin*|*linux*) pkill -f zen_desktop >/dev/null 2>&1 || true ;;
    esac

    safe_clean_dir "$out_dir"
    [ "$PROFILE" = "debug" ] && ldflags="-X main._internalFlag=1 $base_flags"

    # Release mode: hide Windows console window (-H windowsgui)
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
            log_warn "sha256sum / shasum not found, skipping helper integrity check injection (not recommended)."
        fi
        if [ -n "$helper_sha256" ]; then
            ldflags="$ldflags -X main.expectedHelperSHA256=$helper_sha256"
            log_info "helper SHA-256: $helper_sha256"
        fi
    fi

    cp "$DIST_ROOT/common/$LIC_HTML" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/$LIC_JS" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/$ZEN_ERR_JS" "$DESKTOP_APP_DIR/"
    cp "$DIST_ROOT/common/$MANUAL_HTML" "$DESKTOP_APP_DIR/"
    cp "$DESKTOP_CORE_WEB_DIR/ZenChartDraw.js" "$DESKTOP_APP_DIR/"
    cp "$DESKTOP_CORE_WEB_DIR/ZenHQChartCompat.js" "$DESKTOP_APP_DIR/"

    # Replace __ZEN_DEBUG__ placeholder in zen.html (debug=true, release=false)
    local zen_html_file="$DESKTOP_APP_DIR/zen.html"
    if [ -f "$zen_html_file" ]; then
        if [ "$PROFILE" = "debug" ]; then
            sed -i.bak 's/"__ZEN_DEBUG__"/"true"/g' "$zen_html_file" && rm -f "${zen_html_file}.bak"
        else
            sed -i.bak 's/"__ZEN_DEBUG__"/"false"/g' "$zen_html_file" && rm -f "${zen_html_file}.bak"
        fi
    fi

    if ! (
        cd "$DESKTOP_APP_DIR"
        go build -buildvcs=false $GO_TRIMPATH -ldflags "$ldflags" -o "$out_dir/$output_name" .
    ); then
        log_error "Go desktop build failed"
        build_failed=1
    fi

    if [ $build_failed -eq 1 ]; then
        cleanup_desktop_staging
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

    # Incremental build: skip if nothing changed since last build.
    # APK uses WASM+AAR; check WASM source dirs + interface_android.
    # docs/ and LICENSE.md are already checked by the HTML build step.
    # Exclude app/src/main/assets: syncZenAssets writes there during the build
    # and cleanupZenSyncedAssets deletes files afterward, which would otherwise
    # always make app/src appear newer than the APK, defeating incremental builds.
    if ! need_rebuild --exclude "$ANDROID_DIR/zen_mobile/app/src/main/assets" \
        "$output_dir/zen_mobile_universal.apk" \
        "$ANDROID_DIR/web" \
        "$DESKTOP_CORE_WEB_DIR" \
        "$ANDROID_DIR/zen_mobile/app/src" \
        "$DIST_ROOT/$TARGET_WASM/$PROFILE/pkg/$WASM_LIB_NAME" \
        "$DIST_ROOT/common/$LIC_HTML" \
        "$DIST_ROOT/aarch64-linux-android/$PROFILE/zen_android_api.aar" \
        "$ROOT_DIR/src/auth" \
        "$ROOT_DIR/src/common" \
        "$ROOT_DIR/src/key" \
        "$ROOT_DIR/src/lib.rs" \
        "$ROOT_DIR/src/interfaces/mod.rs" \
        "$ROOT_DIR/src/interfaces/interface_wasm" \
        "$ROOT_DIR/src/interfaces/interface_android" \
        "$ROOT_DIR/src/indicators" \
        "$ROOT_DIR/src/kline" \
        "$ROOT_DIR/src/market" \
        "$ROOT_DIR/src/movement" \
        "$ROOT_DIR/src/pivot" \
        "$ROOT_DIR/src/segment" \
        "$ROOT_DIR/src/stroke" \
        "$ROOT_DIR/Cargo.toml" \
        "$ROOT_DIR/Cargo.lock"; then
        log_info "Skipping APK (up-to-date)"
        return 0
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
    "$target_dir/debug/zen_desktop" \
    "$target_dir/release/zen_replay" \
    "$target_dir/debug/zen_replay" 2>/dev/null || true
        done
    fi
    # Gradle / Android 中间产物（regenerable，从未入库）
    rm -rf \
        "$ANDROID_DIR/zen_mobile/app/build" \
        "$ANDROID_DIR/zen_mobile/build" \
        "$ANDROID_DIR/zen_mobile/.gradle" \
        "$ANDROID_DIR/zen_mobile/.kotlin" \
        "$ANDROID_DIR/zen_mobile/.idea" 2>/dev/null || true
    # Gradle 同步到 app/libs/ 的 AAR 副本（regenerable，从未入库）
    rm -f \
        "$ANDROID_DIR/zen_mobile/app/libs/zen_android_api.aar" \
        "$ANDROID_DIR/zen_mobile/app/libs/zen_android_api-sources.jar" 2>/dev/null || true
    cleanup_desktop_staging
    cleanup_replay_staging
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
    replay)
        local replay_target="$NATIVE_TARGET"
        local replay_name
        [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]] && replay_target="$TARGET_X86_64"
        replay_name="$(replay_binary_name "$replay_target")"
        check_and_print "Replay" "$(replay_output_dir "$replay_target")/$replay_name"
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
        local replay_target="$NATIVE_TARGET"
        local replay_name
        [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == MSYS* || "$OS_TYPE" == CYGWIN* ]] && replay_target="$TARGET_X86_64"
        replay_name="$(replay_binary_name "$replay_target")"
        check_and_print "Replay" "$(replay_output_dir "$replay_target")/$replay_name"
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

    sips -z "$width" "$width" "$src" --out "$dst" >/dev/null 2>&1 || {
        cp "$src" "$dst"
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
    local readme_src="$SCRIPT_DIR/$README_MD"
    local readme_dst="$SCRIPT_DIR/$README_HTML"
    local tmp_dir="$SCRIPT_DIR/_tmp_inline_imgs"

    if [ ! -f "$readme_src" ]; then
        log_warn "$README_MD not found, skipping readme render"
        return
    fi

    if ! command_exists pandoc; then
        log_warn "pandoc not found, skipping readme render"
        return
    fi

    log_info "Rendering $README_MD → $README_HTML..."

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    # Resize only the images that exist in qrcode/
    local alipay_uri="" qq_uri=""
    if [[ -f "$SCRIPT_DIR/qrcode/alipay.png" ]]; then
        resize_image_for_readme "$SCRIPT_DIR/qrcode/alipay.png" "$tmp_dir/alipay.png" 100
        alipay_uri="$(image_to_data_uri "$tmp_dir/alipay.png")"
    fi
    if [[ -f "$SCRIPT_DIR/qrcode/qq.png" ]]; then
        resize_image_for_readme "$SCRIPT_DIR/qrcode/qq.png" "$tmp_dir/qq.png" 100
        qq_uri="$(image_to_data_uri "$tmp_dir/qq.png")"
    fi

    pandoc -s --self-contained --resource-path="$SCRIPT_DIR:.." --css="$SCRIPT_DIR/$README_CSS" -o "$readme_dst" "$readme_src" 2>/dev/null || {
        log_warn "Failed to render $README_HTML"
        rm -rf "$tmp_dir"
        return
    }

    [[ -n "$alipay_uri" ]] && perl -pi -e 's|src="qrcode/alipay\.png"|src="'"$alipay_uri"'"|' "$readme_dst"
    [[ -n "$qq_uri" ]] && perl -pi -e 's|src="qrcode/qq\.png"|src="'"$qq_uri"'"|' "$readme_dst"

    rm -rf "$tmp_dir"
    log_info "$README_HTML: $readme_dst"
}

# ==================== Main Dispatch ====================

case "$MODE" in
    desktop|replay|apk|all)
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
    replay)
        build_replay
        cleanup_replay_staging
        ;;
    apk)
        build_android
        ;;
    all)
        build_desktop
        cleanup_desktop_staging
        build_replay
        cleanup_replay_staging
        build_android
        ;;
    clean)
        do_clean
        ;;
esac

if [[ "$MODE" != "clean" ]] && [[ "$QUIET" != "1" ]]; then
    show_summary
fi
