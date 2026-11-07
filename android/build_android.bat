@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "ANDROID_DIR=%SCRIPT_DIR%"
set "PROFILE=%1"
if "%PROFILE%"=="" set PROFILE=release
set "OUTPUT_DIR=%~2"
if "%OUTPUT_DIR%"=="" set "OUTPUT_DIR=%ANDROID_DIR%..\dist\aarch64-linux-android\%PROFILE%\zen_mobile"

echo.
echo ------------------------------------------------------------
echo   Building Android APK (%PROFILE%)
echo ------------------------------------------------------------
echo.

if not defined JAVA_HOME (
    for %%d in (
        "D:\Program Files\Android\Android Studio\jbr"
        "C:\Program Files\Android\Android Studio\jbr"
    ) do (
        if exist "%%~d\bin\java.exe" set "JAVA_HOME=%%~d"
    )
)
if not defined JAVA_HOME (
    echo [ERROR] JAVA_HOME not set and could not auto-detect JDK.
    exit /b 1
)
echo [INFO] Using Java: %JAVA_HOME%

set "ANDROID_SDK="
if defined ANDROID_HOME (
    if exist "%ANDROID_HOME%" set "ANDROID_SDK=%ANDROID_HOME%"
)
if not defined ANDROID_SDK (
    if defined ANDROID_SDK_ROOT (
        if exist "%ANDROID_SDK_ROOT%" set "ANDROID_SDK=%ANDROID_SDK_ROOT%"
    )
)
if not defined ANDROID_SDK (
    for %%d in (
        "%LOCALAPPDATA%\Android\Sdk"
        "D:\Android\Sdk"
        "C:\Android\Sdk"
    ) do (
        if exist "%%~d" (
            set "ANDROID_SDK=%%~d"
            goto :sdk_found
        )
    )
)
:sdk_found
if not defined ANDROID_SDK (
    echo [ERROR] Android SDK not found. Set ANDROID_HOME or install Android Studio.
    exit /b 1
)
echo [INFO] Using Android SDK: %ANDROID_SDK%

call :detect_ndk
if errorlevel 1 exit /b 1

set "SDK_PATH_FWD=%ANDROID_SDK:\=/%"
echo sdk.dir=%SDK_PATH_FWD%> "%ANDROID_DIR%zen_mobile\local.properties"
if defined ANDROID_NDK_HOME (
    set "NDK_PATH_FWD=%ANDROID_NDK_HOME:\=/%"
    echo ndk.dir=%NDK_PATH_FWD%>> "%ANDROID_DIR%zen_mobile\local.properties"
)

set "GRADLE_CMD=%ANDROID_DIR%zen_mobile\gradlew.bat"
if not exist "%GRADLE_CMD%" (
    echo [ERROR] gradlew.bat not found at %GRADLE_CMD%
    exit /b 1
)

if not defined ZEN_ANDROID_STORE_FILE set "ZEN_ANDROID_STORE_FILE=%USERPROFILE%\.android\zen_release.keystore"
if not defined ZEN_ANDROID_KEY_ALIAS set "ZEN_ANDROID_KEY_ALIAS=zen_release"

if not defined ZEN_ANDROID_STORE_PASSWORD (
    echo [ERROR] ZEN_ANDROID_STORE_PASSWORD not set. Please set it as an environment variable.
    exit /b 1
)
if not defined ZEN_ANDROID_KEY_PASSWORD (
    echo [ERROR] ZEN_ANDROID_KEY_PASSWORD not set. Please set it as an environment variable.
    exit /b 1
)

if not exist "%ZEN_ANDROID_STORE_FILE%" (
    echo [ERROR] Release keystore not found at %ZEN_ANDROID_STORE_FILE%
    echo [INFO] Generate it with:
    echo   keytool -genkeypair -v -keystore "%USERPROFILE%\.android\zen_release.keystore" -alias zen_release -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Zen Plugin, OU=Zen, O=Zen, L=Shanghai, ST=Shanghai, C=CN"
    exit /b 1
)

pushd "%ANDROID_DIR%zen_mobile"

REM Clean stale compressed_assets intermediates to avoid "already contains entry"
REM errors when syncZenAssets rewrites pkg/tdx_zen_bg.wasm between builds. This tree
REM is shared with macOS, so jars recorded by the other OS survive into this run.
if exist "app\build\intermediates\compressed_assets" rd /s /q "app\build\intermediates\compressed_assets"

if /I "%PROFILE%"=="debug" (
    call gradlew.bat --warning-mode none --no-configuration-cache -PzenProfile="%PROFILE%" assembleDebug
) else (
    call gradlew.bat --warning-mode none --no-configuration-cache -PzenProfile="%PROFILE%" assembleRelease
)
set "GRADLE_ERR=!ERRORLEVEL!"
popd

if !GRADLE_ERR! neq 0 (
    echo [ERROR] Gradle build failed with error code !GRADLE_ERR!.
    exit /b 1
)

if /I "%PROFILE%"=="debug" (
    set "APK_DIR=%ANDROID_DIR%zen_mobile\app\build\outputs\apk\debug"
) else (
    set "APK_DIR=%ANDROID_DIR%zen_mobile\app\build\outputs\apk\release"
)

set "APK_FILE="
for %%f in ("!APK_DIR!\*.apk") do set "APK_FILE=%%f"
if not defined APK_FILE (
    echo [ERROR] APK not found in !APK_DIR!
    exit /b 1
)

if not exist "!OUTPUT_DIR!" mkdir "!OUTPUT_DIR!"
copy /Y "!APK_FILE!" "!OUTPUT_DIR!\zen_mobile_universal.apk" >nul
if errorlevel 1 (
    echo [ERROR] Failed to copy APK to output directory.
    exit /b 1
)

call :verify_apk_signature "!OUTPUT_DIR!\zen_mobile_universal.apk"
if errorlevel 1 exit /b 1

echo [OK] APK: !OUTPUT_DIR!\zen_mobile_universal.apk
exit /b 0

REM ---------------------------------------------------------------------------
REM APK signature check (release only). Gradle signs during assembleRelease, so
REM this is not a build step -- it is the gate that says the APK we just shipped
REM is signed by the release key rather than silently falling back to a debug
REM certificate. apksigner not installed is an environment gap -> [WARN] and
REM continue; installed but failing means the artifact is not shippable ->
REM [ERROR] and stop. Same wording as android\build_android.sh.
REM ---------------------------------------------------------------------------
:verify_apk_signature

set "AVS_APK=%~1"
if /I not "%PROFILE%"=="release" exit /b 0
if not exist "!AVS_APK!" exit /b 0

set "AVS_TOOL="
where apksigner >nul 2>&1
if "!ERRORLEVEL!"=="0" set "AVS_TOOL=apksigner"
if not defined AVS_TOOL (
    for /d %%k in ("%ANDROID_SDK%\build-tools\*") do (
        if exist "%%~k\apksigner.bat" set "AVS_TOOL=%%~k\apksigner.bat"
    )
)
if not defined AVS_TOOL (
    echo [WARN] APK sign check SKIPPED: apksigner not found -- install Android SDK Build-Tools with sdkmanager, or from https://developer.android.google.cn/studio
    exit /b 0
)

REM Success prints only the OK line; the tool's own output stays in a temp log
REM and is dumped solely when it exits non-zero.
set "AVS_LOG=%TEMP%\zen_apksign_%RANDOM%.log"
"!AVS_TOOL!" verify --print-certs "!AVS_APK!" > "!AVS_LOG!" 2>&1
set "AVS_RC=!ERRORLEVEL!"
if not "!AVS_RC!"=="0" (
    echo [ERROR] APK sign check failed ^(rc=!AVS_RC!^): !AVS_APK!
    type "!AVS_LOG!"
    del "!AVS_LOG!" >nul 2>&1
    exit /b 1
)
findstr /r /c:"^Signer #1 certificate SHA-256 digest: [0-9a-fA-F]" "!AVS_LOG!" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] APK sign check failed: no signer certificate in !AVS_APK!
    type "!AVS_LOG!"
    del "!AVS_LOG!" >nul 2>&1
    exit /b 1
)
findstr /l /c:"Android Debug" "!AVS_LOG!" >nul 2>&1
if not errorlevel 1 (
    echo [ERROR] APK sign check failed: !AVS_APK! is signed with an Android debug certificate
    del "!AVS_LOG!" >nul 2>&1
    exit /b 1
)
del "!AVS_LOG!" >nul 2>&1
echo [INFO] APK sign check: OK

exit /b 0

:detect_ndk
REM Check if ANDROID_NDK_HOME is already set and valid
if defined ANDROID_NDK_HOME (
    if exist "%ANDROID_NDK_HOME%\meta\platforms.json" (
        echo [INFO] Using ANDROID_NDK_HOME: %ANDROID_NDK_HOME%
        exit /b 0
    )
)
REM Search for NDK in SDK directories
set "ANDROID_NDK_HOME="
for /d %%v in ("%ANDROID_SDK%\ndk\*") do (
    if exist "%%~v\meta\platforms.json" (
        set "ANDROID_NDK_HOME=%%~v"
        goto :ndk_found
    )
)
:ndk_found
if defined ANDROID_NDK_HOME (
    echo [INFO] Auto-detected NDK: %ANDROID_NDK_HOME%
) else (
    echo [ERROR] No NDK found in %ANDROID_SDK%\ndk - APK build requires NDK. Install via Android Studio SDK Manager.
    exit /b 1
)
exit /b 0
