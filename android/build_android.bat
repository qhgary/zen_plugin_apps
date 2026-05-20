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
if /I "%PROFILE%"=="debug" (
    call gradlew.bat --warning-mode none --no-configuration-cache -PzenProfile="%PROFILE%" clean assembleDebug
) else (
    call gradlew.bat --warning-mode none --no-configuration-cache -PzenProfile="%PROFILE%" clean assembleRelease
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
echo [OK] APK: !OUTPUT_DIR!\zen_mobile_universal.apk
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
    echo [WARN] No NDK found in %ANDROID_SDK%\ndk
)
exit /b 0
