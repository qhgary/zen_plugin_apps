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



if /I not "%PROFILE%"=="debug" if /I not "%PROFILE%"=="release" (

    echo [ERROR] Unknown profile: %PROFILE% ^(expected: debug or release^)

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
powershell -Command "$css = Get-Content '!CSS_SRC!' -Raw -Encoding UTF8; $html = Get-Content '!TEMP_HTML!' -Raw -Encoding UTF8; $html = $html -replace '(?s)<style>.*?</style>', ('<style>' + $css + '</style>'); $html | Set-Content '!README_DST!' -NoNewline -Encoding UTF8"
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
call :check_java_tools
if errorlevel 1 (
    echo [WARN] Java not found, skipping APK build.
) else (
    call :build_apk || exit /b 1
)
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



:cleanup_desktop_staging

if exist "%DESKTOP_APP_DIR%\jscommon" rd /s /q "%DESKTOP_APP_DIR%\jscommon"

if exist "%DESKTOP_APP_DIR%\pkg" rd /s /q "%DESKTOP_APP_DIR%\pkg"

mkdir "%DESKTOP_APP_DIR%\jscommon" >nul 2>nul

mkdir "%DESKTOP_APP_DIR%\pkg" >nul 2>nul

del /Q /F "%DESKTOP_APP_DIR%\ZenHQChartCompat.js" 2>nul

del /Q /F "%DESKTOP_APP_DIR%\ZenChartDraw.js" 2>nul

del /Q /F "%DESKTOP_APP_DIR%\license_agreement.html" 2>nul

del /Q /F "%DESKTOP_APP_DIR%\license_agreement.js" 2>nul

del /Q /F "%DESKTOP_APP_DIR%\zen_auth_helper" 2>nul

del /Q /F "%DESKTOP_APP_DIR%\zen_auth_helper.exe" 2>nul

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
    echo [ERROR] Missing WASM package in %DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg
    echo [ERROR] Please place the pre-built WASM package in applications\dist\%TARGET_WASM%\%PROFILE%\pkg\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.html" (
    echo [ERROR] Missing license HTML in %DIST_ROOT%\common\license_agreement.html
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.js" (
    echo [ERROR] Missing license JS in %DIST_ROOT%\common\license_agreement.js
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
call :cleanup_desktop_staging

xcopy /E /I /Y "%DESKTOP_CORE_WEB%\jscommon" "%DESKTOP_APP_DIR%\jscommon\" >nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.testdata*" 2>nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.NetworkFilterTest.js" 2>nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.regressiontest.js" 2>nul

copy /Y "%DESKTOP_CORE_WEB%\ZenHQChartCompat.js" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DESKTOP_CORE_WEB%\ZenChartDraw.js" "%DESKTOP_APP_DIR%\" >nul

xcopy /E /I /Y "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DESKTOP_APP_DIR%\pkg\" >nul

copy /Y "%DIST_ROOT%\common\license_agreement.html" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\license_agreement.js" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\Manual.html" "%DESKTOP_APP_DIR%\" >nul

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

set "LDFLAGS=-s -w -X main._internalFlag=0"
if /I "%PROFILE%"=="debug" set "LDFLAGS=-X main._internalFlag=1"

echo -- Compiling Go desktop app...

cd /d "%DESKTOP_APP_DIR%"

go build -ldflags "%LDFLAGS%" -o "..\..\dist\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe" .

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

if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package in %DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg
    echo [ERROR] Please place the pre-built WASM package in applications\dist\%TARGET_WASM%\%PROFILE%\pkg\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.html" (
    echo [ERROR] Missing license HTML in %DIST_ROOT%\common\license_agreement.html
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\license_agreement.js" (
    echo [ERROR] Missing license JS in %DIST_ROOT%\common\license_agreement.js
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

if exist "%DIST_ROOT%\aarch64-linux-android" rd /s /q "%DIST_ROOT%\aarch64-linux-android"

if exist "%DIST_ROOT%\%TARGET_X86_64%\debug\zen_desktop" rd /s /q "%DIST_ROOT%\%TARGET_X86_64%\debug\zen_desktop"

if exist "%DIST_ROOT%\%TARGET_X86_64%\release\zen_desktop" rd /s /q "%DIST_ROOT%\%TARGET_X86_64%\release\zen_desktop"

call :cleanup_desktop_staging

echo [INFO] Application artifacts cleaned.

exit /b 0



:show_summary

if not "%QUIET%"=="1" (

    echo.

    echo ============================================================

    echo   BUILD SUMMARY (%MODE%, %PROFILE%)

    echo ============================================================

    if /I "%MODE%"=="desktop" (

        echo   Desktop:  %DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe

        goto :summary_done

    )

    if /I "%MODE%"=="apk" (

        echo   Android:  %DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk

        goto :summary_done

    )

    if /I "%MODE%"=="all" (

        echo   Desktop:  %DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe

        if exist "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk" (

            echo   Android:  %DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk

        )

        goto :summary_done

    )

)

:summary_done

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

echo.

echo Notes:

echo   - No intermediate artifacts are cleaned after build

echo   - Use 'clean' to remove all build artifacts

echo.

echo Tool requirements:

echo   desktop: go (https://go.dev/dl/)

echo   apk: java JDK 17+, android-sdk (https://developer.android.com/studio)

exit /b 0

