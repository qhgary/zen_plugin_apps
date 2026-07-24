@echo off

setlocal enabledelayedexpansion



chcp 65001 >nul 2>&1

cd /d "%~dp0"



set "MODE=%~1"

if "%MODE%"=="" set "MODE=all"

set "PROFILE=%~2"

if "%PROFILE%"=="" set "PROFILE=release"

set "QUIET=%~3"



if /I "%MODE%"=="help" goto :help

if /I "%MODE%"=="-h" goto :help

if /I "%MODE%"=="--help" goto :help



set "VALID_MODE="

for %%m in (clean desktop apk all) do (

    if /I "%MODE%"=="%%m" set "VALID_MODE=1"

)



if not defined VALID_MODE (

    echo [ERROR] Unknown mode: %MODE%

    echo.

    goto :help

)



if /I not "%PROFILE%"=="debug" if /I not "%PROFILE%"=="release" if /I not "%PROFILE%"=="diag" (
    echo [ERROR] Unknown profile: %PROFILE% ^(expected: debug, release, or diag^)
    echo.
    goto :help
)



set "DIST_ROOT=%CD%\dist"

set "TARGET_WASM=wasm32-unknown-unknown"

set "TARGET_X86_64=x86_64-pc-windows-msvc"

set "DESKTOP_APP_DIR=%CD%\zen_desktop\app"

set "DESKTOP_CORE_WEB=%CD%\HQChart"

set "ANDROID_DIR=%CD%\android"

set "DOCS_DIR=%CD%\..\docs"

set "UI_VERSION=1.4.3"
set "UI_VERSION_FULL=V1.4.3"

REM ==================== Android Env Report (detect only, do not load^) ====================

REM Reporting-only: this script does not load any .env.android or act on
REM these values. The zen_plugin coordinator is responsible for setting
REM them via zen_plugin\.env.android; standalone users must export them
REM in their shell or source their own .env.android.
call :report_android_env
goto :mode_dispatch

:report_android_env
if /I not "%PROFILE%"=="release" exit /b 0
if /I not "%MODE%"=="apk" if /I not "%MODE%"=="all" exit /b 0
set "MISSING="
if "%ZEN_ANDROID_STORE_FILE%"=="" set "MISSING=%MISSING% ZEN_ANDROID_STORE_FILE"
if "%ZEN_ANDROID_STORE_PASSWORD%"=="" set "MISSING=%MISSING% ZEN_ANDROID_STORE_PASSWORD"
if "%ZEN_ANDROID_KEY_ALIAS%"=="" set "MISSING=%MISSING% ZEN_ANDROID_KEY_ALIAS"
if "%ZEN_ANDROID_KEY_PASSWORD%"=="" set "MISSING=%MISSING% ZEN_ANDROID_KEY_PASSWORD"
if not "%MISSING%"=="" (
    echo [WARN] Android signing env vars not set:%MISSING%
    echo [WARN] Release APK will be unsigned. Set them in your shell ^(or
    echo [WARN] source a .env.android you provisioned^) to enable signing.
) else (
    echo [INFO] Android signing env vars: present ^(STORE_FILE=%ZEN_ANDROID_STORE_FILE%, ALIAS=%ZEN_ANDROID_KEY_ALIAS%^)
)
exit /b 0

:mode_dispatch
if /I "%MODE%"=="clean" goto :do_clean

if /I "%MODE%"=="desktop" goto :mode_desktop

if /I "%MODE%"=="apk" goto :mode_apk

if /I "%MODE%"=="all" goto :mode_all

goto :eof



:render_readme
set "README_SRC=%~dp0README.md"
set "README_DST=%~dp0README.html"
set "CSS_SRC=%~dp0README.css"

if not exist "!README_SRC!" (
    echo [WARN] README.md not found, skipping readme render
    exit /b 0
)

where pandoc >nul 2>&1
if errorlevel 1 (
    echo [WARN] pandoc not found, skipping readme render
    exit /b 0
)

echo [INFO] Rendering README.md - README.html...
rem Render to temp file first
set "TEMP_HTML=%TEMP%\zen_readme_temp.html"
pandoc -s -o "!TEMP_HTML!" "!README_SRC!" 2>nul
if errorlevel 1 (
    echo [WARN] Failed to render README
    exit /b 0
)

rem Inject CSS into the generated HTML (replace pandoc default styles with our CSS)
powershell -NoProfile -Command "$css = Get-Content '!CSS_SRC!' -Raw -Encoding UTF8; $html = Get-Content '!TEMP_HTML!' -Raw -Encoding UTF8; $html = $html -replace '(?s)<style>.*?</style>', ('<style>' + $css + '</style>'); $html | Set-Content '!README_DST!' -NoNewline -Encoding UTF8"
del "!TEMP_HTML!" >nul 2>&1

echo [INFO] README: !README_DST!
exit /b 0



:mode_desktop
call :render_readme
call :check_go_tools || exit /b 1
call :build_desktop || exit /b 1
call :cleanup_desktop_staging
call :clean_dist_intermediates
call :show_summary
exit /b 0



:mode_apk
call :render_readme
call :check_android_signing
call :check_java_tools || exit /b 1
call :check_android_ndk || exit /b 1
call :build_apk || exit /b 1
call :clean_dist_intermediates
call :show_summary
exit /b 0



:mode_all
call :render_readme
call :check_go_tools || exit /b 1
call :build_desktop || exit /b 1
call :cleanup_desktop_staging
call :check_android_signing
call :check_java_tools || exit /b 1
call :check_android_ndk || exit /b 1
call :build_apk || exit /b 1
call :clean_dist_intermediates
call :show_summary
exit /b 0



:check_go_tools

where go >nul 2>&1

if errorlevel 1 (

    echo [ERROR] Go is not installed.

    echo.

    echo To build zen_desktop, please install Go:

    echo   Download: https://go.dev/dl/

    echo   Or: choco install golang ^(Windows with Chocolatey^)

    exit /b 1

)

for /f "tokens=*" %%v in ('go version 2^>^&1') do echo [INFO] Go found: %%v

exit /b 0


:check_android_signing

if "%ZEN_ANDROID_STORE_FILE%"=="" set "ZEN_ANDROID_STORE_FILE=%USERPROFILE%\.android\zen_release.keystore"
if "%ZEN_ANDROID_KEY_ALIAS%"=="" set "ZEN_ANDROID_KEY_ALIAS=zen_release"

if "%ZEN_ANDROID_STORE_PASSWORD%"=="" (
    echo [ERROR] ZEN_ANDROID_STORE_PASSWORD not set. Please set it as an environment variable.
    exit /b 1
)
if "%ZEN_ANDROID_KEY_PASSWORD%"=="" (
    echo [ERROR] ZEN_ANDROID_KEY_PASSWORD not set. Please set it as an environment variable.
    exit /b 1
)

echo.
echo ------------------------------------------------------------
echo   Android Signing Config
echo ------------------------------------------------------------
echo   ZEN_ANDROID_STORE_FILE     = %ZEN_ANDROID_STORE_FILE%
echo   ZEN_ANDROID_STORE_PASSWORD = ****
echo   ZEN_ANDROID_KEY_ALIAS      = %ZEN_ANDROID_KEY_ALIAS%
echo   ZEN_ANDROID_KEY_PASSWORD   = ****
echo ------------------------------------------------------------
echo.

exit /b 0



:check_java_tools

where java >nul 2>&1

if not errorlevel 1 goto :java_found

if defined JAVA_HOME if exist "!JAVA_HOME!\bin\java.exe" (

    set "PATH=!JAVA_HOME!\bin;!PATH!"

    where java >nul 2>&1

    if not errorlevel 1 goto :java_found

)

for %%d in (

    "D:\Program Files\Android\Android Studio\jbr"

    "C:\Program Files\Android\Android Studio\jbr"

) do (

    if exist "%%~d\bin\java.exe" (

        set "JAVA_HOME=%%~d"

        set "PATH=%%~d\bin;!PATH!"

        where java >nul 2>&1

        if not errorlevel 1 goto :java_found

    )

)

echo [ERROR] Java ^(JDK 17+^) is not installed.

echo.

echo To build Android APK, please install:

echo   Download JDK 17+: https://adoptium.net/

echo   Or install Android Studio: https://developer.android.com/studio

exit /b 1

:java_found

for /f "tokens=3" %%v in ('java -version 2^>^&1 ^| findstr /i "version"') do set "JAVA_VER=%%v"

set "JAVA_VER=!JAVA_VER:"=!"

for /f "tokens=1 delims=." %%a in ("!JAVA_VER!") do set "JAVA_MAJOR=%%a"

if !JAVA_MAJOR! LSS 17 (

    echo [ERROR] JDK 17+ is required for Android builds. Found: !JAVA_VER!

    echo Please install JDK 17 or higher.

    exit /b 1

)

echo [INFO] Java found: !JAVA_VER!

exit /b 0



:check_android_ndk
REM Locate Android SDK first (mirror of :detect_sdk in build_android.bat).
set "_ndk_sdk="
if defined ANDROID_HOME if exist "%ANDROID_HOME%" set "_ndk_sdk=%ANDROID_HOME%"
if not defined _ndk_sdk if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%" set "_ndk_sdk=%ANDROID_SDK_ROOT%"
if not defined _ndk_sdk (
    for %%d in (
        "%LOCALAPPDATA%\Android\Sdk"
        "D:\Android\Sdk"
        "C:\Android\Sdk"
    ) do (
        if exist "%%~d" (
            set "_ndk_sdk=%%~d"
        )
    )
)
if not defined _ndk_sdk (
    echo [WARN] Android SDK not found - cannot locate NDK. Skipping APK build.
    exit /b 1
)
REM NDK pre-set and valid?
if defined ANDROID_NDK_HOME if exist "%ANDROID_NDK_HOME%\meta\platforms.json" exit /b 0
REM Otherwise search SDK/ndk/* for a valid install.
for /d %%v in ("%_ndk_sdk%\ndk\*") do (
    if exist "%%~v\meta\platforms.json" exit /b 0
)
echo [WARN] Android NDK not found under %_ndk_sdk%\ndk - skipping APK build.
echo [WARN] Install via Android Studio SDK Manager to enable APK builds.
exit /b 1



:safe_clean_dir
REM Preserves zen_license.key and zen_watchlist.json across clean.
set "DIR=%~1"
set "TEMP_BACKUP=%TEMP%\zen_application_preserve_%RANDOM%"
mkdir "!TEMP_BACKUP!" 2>nul
if exist "!DIR!\zen_license.key" copy /Y "!DIR!\zen_license.key" "!TEMP_BACKUP!\" >nul
if exist "!DIR!\zen_watchlist.json" copy /Y "!DIR!\zen_watchlist.json" "!TEMP_BACKUP!\" >nul
rd /s /q "!DIR!" 2>nul
mkdir "!DIR!" 2>nul
if exist "!TEMP_BACKUP!\zen_license.key" copy /Y "!TEMP_BACKUP!\zen_license.key" "!DIR!\" >nul
if exist "!TEMP_BACKUP!\zen_watchlist.json" copy /Y "!TEMP_BACKUP!\zen_watchlist.json" "!DIR!\" >nul
rd /s /q "!TEMP_BACKUP!" 2>nul
exit /b 0

:cleanup_desktop_staging

if exist "%DESKTOP_APP_DIR%\jscommon" rd /s /q "%DESKTOP_APP_DIR%\jscommon"

if exist "%DESKTOP_APP_DIR%\pkg" rd /s /q "%DESKTOP_APP_DIR%\pkg"

mkdir "%DESKTOP_APP_DIR%\jscommon" >nul 2>nul

mkdir "%DESKTOP_APP_DIR%\pkg" >nul 2>nul
:cleanup_desktop_staging

if exist "%DESKTOP_APP_DIR%\jscommon" rd /s /q "%DESKTOP_APP_DIR%\jscommon"
if exist "%DESKTOP_APP_DIR%\pkg" rd /s /q "%DESKTOP_APP_DIR%\pkg"

for %%f in (
    ZenHQChartCompat.js
    ZenChartDraw.js
    license_agreement.html
    license_agreement.js
    manual.html
    zen_auth_helper
    zen_auth_helper.exe
) do (
    if exist "%DESKTOP_APP_DIR%\%%f" (
        powershell -NoProfile -Command "Remove-Item -Path '%DESKTOP_APP_DIR%\%%f' -Force -ErrorAction SilentlyContinue"
    )
)

exit /b 0


:clean_dist_intermediates

exit /b 0



:remove_empty_dir

if exist "%~1" (

    dir "%~1" /b /a 2>nul | findstr /r "." >nul

    if errorlevel 1 rd /s /q "%~1" 2>nul

)

exit /b 0



:prepare_desktop_staging
if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package
    echo [ERROR] Please place the pre-built WASM package in applications\dist\wasm32-unknown-unknown\%PROFILE%\pkg\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.html" (
    echo [ERROR] Missing license HTML
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.js" (
    echo [ERROR] Missing license JS
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
call :cleanup_desktop_staging

echo [INFO] Packing closed-source deps: helper ^(%TARGET_X86_64%^), wasm ^(%TARGET_WASM%^), html

xcopy /E /I /Y "%DESKTOP_CORE_WEB%\jscommon" "%DESKTOP_APP_DIR%\jscommon\" >nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.testdata*" 2>nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.NetworkFilterTest.js" 2>nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.regressiontest.js" 2>nul

copy /Y "%DESKTOP_CORE_WEB%\ZenHQChartCompat.js" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DESKTOP_CORE_WEB%\ZenChartDraw.js" "%DESKTOP_APP_DIR%\" >nul

xcopy /E /I /Y "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DESKTOP_APP_DIR%\pkg\" >nul

copy /Y "%DIST_ROOT%\common\license_agreement.html" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\license_agreement.js" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\manual.html" "%DESKTOP_APP_DIR%\" >nul

exit /b 0



:build_desktop

echo.

echo ============================================================

echo   Building zen_desktop (%PROFILE%) for %TARGET_X86_64%

echo ============================================================

call :prepare_desktop_staging

set "DESKTOP_TARGET=%TARGET_X86_64%"

set "HELPER_NAME=zen_auth_helper.exe"

set "HELPER_SRC=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\%HELPER_NAME%"

if not exist "!HELPER_SRC!" (
    echo [ERROR] Missing helper binary in !HELPER_SRC!
    echo [ERROR] Please place the pre-built helper binary in applications\dist\%DESKTOP_TARGET%\%PROFILE%\
    call :cleanup_desktop_staging
    exit /b 1
)

copy /Y "!HELPER_SRC!" "%DESKTOP_APP_DIR%\%HELPER_NAME%" >nul

REM Helper is already stripped by src/build.bat (build_helper_for_target).
REM Calculate SHA-256 of the (pre-stripped) helper and inject into Go binary
REM via -ldflags. Runtime verifyHelperIntegrity compares the on-disk helper
REM against this value, blocking "swap helper at runtime" attacks.

set "BASE_FLAGS="
set "LDFLAGS=-s -w -X main._internalFlag=0 %BASE_FLAGS%"
if /I "%PROFILE%"=="debug" set "LDFLAGS=-X main._internalFlag=1 %BASE_FLAGS%"

REM Release 模式下隐藏 Windows 控制台窗口
if /I "%PROFILE%"=="release" set "LDFLAGS=%LDFLAGS% -H windowsgui"

if /I "%PROFILE%"=="release" (
    REM Use PowerShell: certutil's multi-line output + case-sensitive findstr
    REM would otherwise capture "SHA256" (the header line's first token) or just
    REM the first 2-char byte pair. PowerShell gives a single 64-char hex line.
    for /f "delims=" %%h in ('powershell -NoProfile -Command "Write-Output ((Get-FileHash -Algorithm SHA256 '%DESKTOP_APP_DIR%\%HELPER_NAME%').Hash.ToLower())"') do (
        if not defined HELPER_SHA256 set "HELPER_SHA256=%%h"
    )
    if defined HELPER_SHA256 (
        set "LDFLAGS=!LDFLAGS! -X main.expectedHelperSHA256=!HELPER_SHA256!"
        echo   helper SHA-256: !HELPER_SHA256!
    ) else (
        echo [WARN] 未计算 helper SHA-256, 将跳过运行时 helper 完整性校验^(不推荐^).
    )
)

echo -- Compiling Go desktop app...

REM Preserve user-owned files (license key / watchlist) across clean.
set "OUT_DIR=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop"
call :safe_clean_dir "!OUT_DIR!"

cd /d "%DESKTOP_APP_DIR%"

go build -buildvcs=false -ldflags "%LDFLAGS%" -o "..\..\dist\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe" .

set "GO_ERR=!ERRORLEVEL!"

cd /d "%~dp0"

if !GO_ERR! neq 0 (

    echo [ERROR] Go desktop build failed

    call :cleanup_desktop_staging

    exit /b 1

)

echo [INFO] Desktop:  %DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe

exit /b 0



:build_apk

echo.

echo ============================================================

echo   Building zen_mobile (%PROFILE%)

echo ============================================================

echo [INFO] Closed-source deps: aar ^(aarch64-linux-android^), wasm ^(%TARGET_WASM%^), html

if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package
    echo [ERROR] Please place the pre-built WASM package in applications\dist\wasm32-unknown-unknown\%PROFILE%\pkg\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.html" (
    echo [ERROR] Missing license HTML
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.js" (
    echo [ERROR] Missing license JS
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
call "%ANDROID_DIR%\build_android.bat" %PROFILE%

set "ANDROID_ERR=!ERRORLEVEL!"

if !ANDROID_ERR! neq 0 exit /b 1

echo [INFO] Android:  %DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk

exit /b 0



:do_clean

echo.

echo ============================================================

echo   Cleaning Application Artifacts

echo ============================================================

REM Clean all generated artifacts, preserving closed-source binaries
for /d %%d in ("%DIST_ROOT%\*") do (
    if exist "%%~d\release\zen_mobile" rd /s /q "%%~d\release\zen_mobile"
    if exist "%%~d\debug\zen_mobile" rd /s /q "%%~d\debug\zen_mobile"
    if exist "%%~d\release\zen_desktop" rd /s /q "%%~d\release\zen_desktop"
    if exist "%%~d\debug\zen_desktop" rd /s /q "%%~d\debug\zen_desktop"
)

REM Gradle / Android intermediate outputs (regenerable, never checked in)
if exist "%ANDROID_DIR%\zen_mobile\app\build" rd /s /q "%ANDROID_DIR%\zen_mobile\app\build"
if exist "%ANDROID_DIR%\zen_mobile\build" rd /s /q "%ANDROID_DIR%\zen_mobile\build"
if exist "%ANDROID_DIR%\zen_mobile\.gradle" rd /s /q "%ANDROID_DIR%\zen_mobile\.gradle"
if exist "%ANDROID_DIR%\zen_mobile\.kotlin" rd /s /q "%ANDROID_DIR%\zen_mobile\.kotlin"
if exist "%ANDROID_DIR%\zen_mobile\.idea" rd /s /q "%ANDROID_DIR%\zen_mobile\.idea"

call :cleanup_desktop_staging

echo [INFO] Application artifacts cleaned.

exit /b 0



:show_summary

if not "%QUIET%"=="1" (

    echo.

    echo ============================================================

    echo   BUILD SUMMARY ^(%MODE%, %PROFILE%^)

    echo ============================================================

    if /I "%MODE%"=="desktop" (

        call :check_and_print "Desktop" "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe"

        goto :summary_done

    )

    if /I "%MODE%"=="apk" (

        if "%ZEN_ANDROID_STORE_FILE%"=="" (
            echo   Android:  [SKIPPED] Missing signing configuration
        ) else (
            call :check_and_print "Android" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk"
        )

        goto :summary_done

    )

    if /I "%MODE%"=="all" (

        call :check_and_print "Desktop" "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe"

        if "%ZEN_ANDROID_STORE_FILE%"=="" (
            echo   Android:  [SKIPPED] Missing signing configuration
        ) else (
            call :check_and_print "Android" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk"
        )

        goto :summary_done

    )

)

:summary_done

exit /b 0

:check_and_print
set "LBL=%~1"
set "PTH=%~2"
if exist "!PTH!" (
    echo   !LBL!: !PTH!
) else (
    echo   !LBL!: [FAILED]
)
exit /b 0



:help

echo.

echo Usage: applications\build.bat [MODE] [PROFILE]

echo.

echo MODE (default: all):

echo   desktop  Build zen_desktop app only

echo   apk      Build zen_mobile APK only

echo   all      Build both desktop and apk

echo   clean    Clean all build artifacts

echo   help     Show this help

echo.

echo PROFILE (default: release):

echo   release  Release build (optimized)

echo   debug    Debug build (with logging)

echo   diag     Diagnostic build (verbose logging, slow^)

echo.

echo Notes:

echo   - No intermediate artifacts are cleaned after build

echo   - Use 'clean' to remove all build artifacts

echo.

echo Tool requirements:

echo   desktop: go (https://go.dev/dl/)

echo   apk: java JDK 17+, android-sdk (https://developer.android.com/studio)

exit /b 0

