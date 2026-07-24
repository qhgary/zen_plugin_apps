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
    chmod +x gradlew
    if [ "$PROFILE" = "debug" ]; then
        ./gradlew --warning-mode none --no-problems-report --no-configuration-cache -PzenProfile="$PROFILE" clean assembleDebug
    else
        ./gradlew --warning-mode none --no-problems-report --no-configuration-cache -PzenProfile="$PROFILE" clean assembleRelease
    fi
)

APK_FILE=$(find "$APK_DIR" -name "*.apk" 2>/dev/null | head -1)
if [ -z "$APK_FILE" ]; then
    echo "[ERROR] APK not found in $APK_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$APK_FILE" "$OUTPUT_DIR/zen_mobile_universal.apk"
echo "[OK] APK: $OUTPUT_DIR/zen_mobile_universal.apk"
