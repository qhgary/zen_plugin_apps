#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_DIR="$SCRIPT_DIR"

PROFILE="${1:-release}"
OUTPUT_DIR="${2:-$SCRIPT_DIR/../dist/android/$PROFILE/zen_mobile}"

detect_java_home() {
    local java_home=""
    
    # 检测 JAVA_HOME 环境变量
    if [ -n "${JAVA_HOME:-}" ] && [ -d "$JAVA_HOME" ]; then
        echo "$JAVA_HOME"
        return
    fi
    
    # macOS: 使用 /usr/libexec/java_home
    if command -v /usr/libexec/java_home >/dev/null 2>&1; then
        java_home=$(/usr/libexec/java_home 2>/dev/null || true)
        if [ -n "$java_home" ] && [ -d "$java_home" ]; then
            echo "$java_home"
            return
        fi
    fi
    
    # Linux/Windows: 检测常见路径
    case "$(uname)" in
        Darwin*)
            for dir in \
                /Library/Java/JavaVirtualMachines/*/Contents/Home \
                $HOME/Library/Java/JavaVirtualMachines/*/Contents/Home \
                /opt/homebrew/Cellar/openjdk*/libexec/*/Contents/Home \
                /usr/local/Cellar/openjdk*/libexec/*/Contents/Home
            do
                if [ -d "$dir" ] && [ -f "$dir/bin/java" ]; then
                    echo "$dir"
                    return
                fi
            done
            ;;
        Linux*)
            for dir in \
                /usr/lib/jvm/* \
                $HOME/.sdkman/candidates/java/*
            do
                if [ -d "$dir" ] && [ -f "$dir/bin/java" ]; then
                    echo "$dir"
                    return
                fi
            done
            ;;
        MINGW*|MSYS*|CYGWIN*)
            for dir in \
                "$PROGRAMFILES/Java/"* \
                "${JAVA_HOME:-}" \
                "/c/Program Files/Java/"*
            do
                if [ -n "$dir" ] && [ -d "$dir" ]; then
                    echo "$dir"
                    return
                fi
            done
            ;;
    esac
    
    # 备选方案：通过 java 命令定位
    if command -v java >/dev/null 2>&1; then
        local java_bin=$(command -v java)
        local java_real=""
        if [ -L "$java_bin" ]; then
            java_real=$(readlink -f "$java_bin" 2>/dev/null || true)
        else
            java_real="$java_bin"
        fi
        if [ -n "$java_real" ]; then
            local java_home_dir=$(dirname $(dirname "$java_real"))
            if [ -d "$java_home_dir" ] && [ -f "$java_home_dir/bin/java" ]; then
                echo "$java_home_dir"
                return
            fi
        fi
    fi
    
    echo ""
    return 1
}

JAVA_HOME=$(detect_java_home)
if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME" ]; then
    echo "[ERROR] Java not found. Please install JDK 17+ for Android builds."
    echo "  macOS: brew install openjdk@17"
    echo "  Linux: sudo apt install openjdk-17-jdk (Debian/Ubuntu)"
    echo "         sudo dnf install java-17-openjdk (Fedora/RHEL)"
    echo "  Windows: Download from https://adoptium.net/"
    echo "  Or set JAVA_HOME environment variable."
    exit 1
fi
export JAVA_HOME
echo "[INFO] Using Java: $JAVA_HOME"

echo ""
echo "------------------------------------------------------------"
echo "  Building Android APK ($PROFILE)"
echo "------------------------------------------------------------"

# WASM 已在 build_apps 中先构建，此处直接使用

if [ "$PROFILE" = "debug" ]; then
    APK_DIR="$ANDROID_DIR/zen_mobile/app/build/outputs/apk/debug"
else
    APK_DIR="$ANDROID_DIR/zen_mobile/app/build/outputs/apk/release"
fi

echo "[1/1] Building APK..."

# 动态获取 Android SDK 路径
detect_android_sdk() {
    # 优先使用环境变量 (使用 ${var:-} 避免 unbound variable)
    local android_home=${ANDROID_HOME:-}
    local android_sdk_root=${ANDROID_SDK_ROOT:-}
    
    if [ -n "$android_home" ] && [ -d "$android_home" ]; then
        echo "$android_home"
        return
    fi
    if [ -n "$android_sdk_root" ] && [ -d "$android_sdk_root" ]; then
        echo "$android_sdk_root"
        return
    fi
    # 检查常见位置
    local sdk_dir=""
    for dir in \
        "$HOME/Library/Android/sdk" \
        "/opt/android-sdk" \
        "/usr/local/android-sdk" \
        "/android-sdk"
    do
        if [ -d "$dir" ]; then
            sdk_dir="$dir"
            break
        fi
    done
    if [ -n "$sdk_dir" ]; then
        echo "$sdk_dir"
        return
    fi
    # 检查 sdkmanager
    if command -v sdkmanager &>/dev/null; then
        local sdk_path=$(dirname $(dirname $(dirname $(which sdkmanager))))
        if [ -d "$sdk_path" ]; then
            echo "$sdk_path"
            return
        fi
    fi
    echo "ERROR: Android SDK not found" >&2
    exit 1
}

ANDROID_SDK=$(detect_android_sdk)
export ANDROID_HOME="$ANDROID_SDK"
echo "[INFO] Using Android SDK: $ANDROID_SDK"

# 动态生成 local.properties
echo "sdk.dir=$ANDROID_SDK" > "$ANDROID_DIR/zen_mobile/local.properties"

(
    cd "$ANDROID_DIR/zen_mobile"
    rm -rf app/build/intermediates/compressed_assets
    chmod +x gradlew
    if [ "$PROFILE" = "debug" ]; then
        ./gradlew --warning-mode none --no-problems-report --no-configuration-cache -PzenProfile="$PROFILE" assembleDebug
    else
        ./gradlew --warning-mode none --no-problems-report --no-configuration-cache -PzenProfile="$PROFILE" assembleRelease
    fi
)

APK_FILE=$(find "$APK_DIR" -name "*.apk" 2>/dev/null | head -1)
if [ -z "$APK_FILE" ]; then
    echo "[ERROR] APK not found in $APK_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$APK_FILE" "$OUTPUT_DIR/zen_mobile_universal.apk"

# --- APK signature check (release only) -------------------------------------
# Gradle signs during assembleRelease, so this is not a build step: it is the
# gate that says the APK we just shipped is signed by the release key rather
# than silently falling back to a debug certificate. apksigner not installed is
# an environment gap -> [WARN] and continue; installed but failing means the
# artifact is not shippable -> [ERROR] and stop. Same wording as the REM block
# in android\build_android.bat.
verify_apk_signature() {
    local apk="$1"
    [ "$PROFILE" = "release" ] || return 0
    [ -f "$apk" ] || return 0

    local tool=""
    if command -v apksigner >/dev/null 2>&1; then
        tool="$(command -v apksigner)"
    else
        local candidate
        for candidate in "$ANDROID_SDK"/build-tools/*/apksigner; do
            if [ -x "$candidate" ]; then
                tool="$candidate"
            fi
        done
    fi
    if [ -z "$tool" ]; then
        echo "[WARN] APK sign check SKIPPED: apksigner not found -- install Android SDK Build-Tools with sdkmanager, or from https://developer.android.google.cn/studio"
        return 0
    fi

    local out=""
    local rc=0
    out="$("$tool" verify --print-certs "$apk" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[ERROR] APK sign check failed (rc=$rc): $apk"
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
        fi
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -q '^Signer #1 certificate SHA-256 digest: [0-9a-fA-F]'; then
        echo "[ERROR] APK sign check failed: no signer certificate in $apk"
        printf '%s\n' "$out"
        return 1
    fi
    if printf '%s\n' "$out" | grep -q 'Android Debug'; then
        echo "[ERROR] APK sign check failed: $apk is signed with an Android debug certificate"
        return 1
    fi
    echo "[INFO] APK sign check: OK"
}

if ! verify_apk_signature "$OUTPUT_DIR/zen_mobile_universal.apk"; then
    exit 1
fi

echo "[OK] APK: $OUTPUT_DIR/zen_mobile_universal.apk"
