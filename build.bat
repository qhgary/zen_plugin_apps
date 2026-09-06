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

for %%m in (clean desktop replay apk all) do (

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

REM Security audit: release builds use -trimpath to strip absolute
REM build-machine paths from binaries (panic stacks, runtime.Caller).
REM Does not affect logging (Lshortfile only prints the base filename).
set "GO_TRIMPATH="
if /I "%PROFILE%"=="release" set "GO_TRIMPATH=-trimpath"



set "DIST_ROOT=%CD%\dist"

set "TARGET_X86_64=x86_64-pc-windows-msvc"

set "TARGET_WASM=wasm32-unknown-unknown"

rem HTML/document file names
set "MANUAL_HTML=manual.html"
set "LIC_HTML=license_agreement.html"
set "LIC_JS=license_agreement.js"
set "ZEN_ERR_JS=zen_error_codes.js"
set "LIC_CSS=license_agreement_style.css"
set "WASM_LIB_NAME=tdx_zen_bg.wasm"
set "WASM_JS_NAME=tdx_zen.js"
set "README_MD=README.md"
set "README_HTML=README.html"
set "README_CSS=README.css"

set "DESKTOP_APP_DIR=%CD%\zen_desktop\app"

set "DESKTOP_CORE_WEB=%CD%\HQChart"

set "DESKTOP_CORE_GO=%CD%\zen_desktop\core\go"

set "REPLAY_APP_DIR=%CD%\zen_replay\app"

set "ANDROID_DIR=%CD%\android"

set "DOCS_DIR=%CD%\..\docs"

set "UI_VERSION=1.4.6"
set "UI_VERSION_FULL=V1.4.6"

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

if /I "%MODE%"=="replay" goto :mode_replay

if /I "%MODE%"=="apk" goto :mode_apk

if /I "%MODE%"=="all" goto :mode_all

goto :eof



:render_readme
set "README_SRC=%~dp0%README_MD%"
set "README_DST=%~dp0%README_HTML%"
set "CSS_SRC=%~dp0%README_CSS%"

if not exist "!README_SRC!" (
    echo [WARN] %README_MD% not found, skipping readme render
    exit /b 0
)

where pandoc >nul 2>&1
if errorlevel 1 (
    echo [WARN] pandoc not found, skipping readme render
    exit /b 0
)

echo [INFO] Rendering %README_MD% - %README_HTML%...
rem Render to temp file first
set "TEMP_HTML=%TEMP%\zen_readme_temp.html"
pandoc -s -o "!TEMP_HTML!" "!README_SRC!" 2>nul
if errorlevel 1 (
    echo [WARN] Failed to render %README_HTML%
    exit /b 0
)

rem Inject CSS into the generated HTML (replace pandoc default styles with our CSS)
powershell -NoProfile -Command "$css = Get-Content '!CSS_SRC!' -Raw -Encoding UTF8; $html = Get-Content '!TEMP_HTML!' -Raw -Encoding UTF8; $html = $html -replace '(?s)<style>.*?</style>', ('<style>' + $css + '</style>'); $html | Set-Content '!README_DST!' -NoNewline -Encoding UTF8"
del "!TEMP_HTML!" >nul 2>&1

echo [INFO] %README_HTML%: !README_DST!
exit /b 0



:mode_desktop
call :render_readme
call :check_go_tools || exit /b 1
call :build_desktop || exit /b 1
call :cleanup_desktop_staging
call :clean_dist_intermediates
call :show_summary
exit /b 0



:mode_replay
call :render_readme
call :check_go_tools || exit /b 1
call :build_replay || exit /b 1
call :cleanup_replay_staging
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
call :build_replay || exit /b 1
call :cleanup_replay_staging
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

REM Auto-configure GOPROXY for users in China: if GOPROXY is unset or
REM still the default proxy.golang.org, switch to goproxy.cn mirror.
REM Users who set GOPROXY themselves (e.g. a corporate proxy) are respected.
set "CURRENT_GOPROXY="
for /f "delims=" %%p in ('go env GOPROXY 2^>nul') do set "CURRENT_GOPROXY=%%p"
if /I "!CURRENT_GOPROXY!"=="https://proxy.golang.org,direct" (
    go env -w GOPROXY=https://goproxy.cn,direct
    echo [INFO] GOPROXY auto-set to goproxy.cn ^(default proxy unreachable^)
)

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

if exist "%DESKTOP_APP_DIR%\jscommon" rd /s /q "%DESKTOP_APP_DIR%\jscommon
if exist "%DESKTOP_APP_DIR%\pkg" rd /s /q "%DESKTOP_APP_DIR%\pkg
mkdir "%DESKTOP_APP_DIR%\jscommon" >nul 2>nul
mkdir "%DESKTOP_APP_DIR%\pkg" >nul 2>nul
type NUL > "%DESKTOP_APP_DIR%\jscommon\placeholder.txt" 2>nul
type NUL > "%DESKTOP_APP_DIR%\pkg\placeholder.txt" 2>nul

for %%f in (
    ZenHQChartCompat.js
    ZenChartDraw.js
    !LIC_HTML!
    !LIC_JS!
    !ZEN_ERR_JS!
    !MANUAL_HTML!
    zen_auth_helper
    zen_auth_helper.exe
) do (
    if exist "%DESKTOP_APP_DIR%\%%f" (
        powershell -NoProfile -Command "Remove-Item -Path '%DESKTOP_APP_DIR%\%%f' -Force -ErrorAction SilentlyContinue"
    )
)

REM Recreate empty placeholders for go:embed IDE compatibility
REM (build script overwrites with real files before go build; cleanup restores empties)
type NUL > "%DESKTOP_APP_DIR%\ZenChartDraw.js" 2>nul
type NUL > "%DESKTOP_APP_DIR%\ZenHQChartCompat.js" 2>nul
type NUL > "%DESKTOP_APP_DIR%\!LIC_HTML!" 2>nul
type NUL > "%DESKTOP_APP_DIR%\!LIC_JS!" 2>nul
type NUL > "%DESKTOP_APP_DIR%\!ZEN_ERR_JS!" 2>nul
type NUL > "%DESKTOP_APP_DIR%\zen_auth_helper" 2>nul

REM 删除本地手动 go build 残留的游离二进制（非构建脚本产物）
if exist "%DESKTOP_APP_DIR%\zen_desktop" del /f /q "%DESKTOP_APP_DIR%\zen_desktop" 2>nul
if exist "%DESKTOP_APP_DIR%\zen_desktop.exe" del /f /q "%DESKTOP_APP_DIR%\zen_desktop.exe" 2>nul

exit /b 0


:clean_dist_intermediates

exit /b 0



:remove_empty_dir

if exist "%~1" (

    dir "%~1" /b /a 2>nul | findstr /r "." >nul

    if errorlevel 1 rd /s /q "%~1" 2>nul

)

exit /b 0



:need_rebuild
REM Incremental build check: determines if output needs rebuilding.
REM Usage: call :need_rebuild [--exclude "dir"] "output" "src1" "src2" ...
REM Returns: errorlevel 0 = need rebuild, 1 = can skip
set "RB_OUT="
set "RB_SRCS="
set "RB_EXCLS="
:rb_parse
if "%~1"=="" goto :rb_eval
if /I "%~1"=="--exclude" goto :rb_exclude
if not defined RB_OUT goto :rb_set_out
set "RB_SRCS=!RB_SRCS!,'%~1'"
shift
goto :rb_parse
:rb_set_out
set "RB_OUT=%~1"
if not exist "!RB_OUT!" exit /b 0
shift
goto :rb_parse
:rb_exclude
shift
set "RB_EXCLS=!RB_EXCLS!,'%~1'"
shift
goto :rb_parse
:rb_eval
set "RB_SCRIPT=%TEMP%\zen_need_rebuild_%RANDOM%.ps1"
echo $out='!RB_OUT!' > "%RB_SCRIPT%"
set "RB_SRCS_PS=@()"
if not "!RB_SRCS!"=="" set "RB_SRCS_PS=@(!RB_SRCS:~1!)"
echo $srcs=!RB_SRCS_PS! >> "%RB_SCRIPT%"
set "RB_EXCLS_PS=@()"
if not "!RB_EXCLS!"=="" set "RB_EXCLS_PS=@(!RB_EXCLS:~1!)"
echo $excls=!RB_EXCLS_PS! >> "%RB_SCRIPT%"
echo $exclFulls=@() >> "%RB_SCRIPT%"
echo foreach($e in $excls){ if(Test-Path -LiteralPath $e){ $exclFulls += (Get-Item -LiteralPath $e).FullName } } >> "%RB_SCRIPT%"
echo $outT=(Get-Item -LiteralPath $out).LastWriteTime >> "%RB_SCRIPT%"
echo $need=$false >> "%RB_SCRIPT%"
echo foreach($s in $srcs){ >> "%RB_SCRIPT%"
echo if(-not(Test-Path -LiteralPath $s)){$need=$true;break} >> "%RB_SCRIPT%"
echo $i=Get-Item -LiteralPath $s >> "%RB_SCRIPT%"
echo if($i.PSIsContainer){ >> "%RB_SCRIPT%"
echo foreach($f in (Get-ChildItem -Recurse -LiteralPath $s -File -ErrorAction SilentlyContinue)){ >> "%RB_SCRIPT%"
echo $skip=$false >> "%RB_SCRIPT%"
echo foreach($ex in $exclFulls){ if($f.FullName.StartsWith($ex,'OrdinalIgnoreCase')){$skip=$true;break} } >> "%RB_SCRIPT%"
echo if(-not $skip -and -not $f.Name.StartsWith('.') -and $f.LastWriteTime -gt $outT){$need=$true;break} >> "%RB_SCRIPT%"
echo } >> "%RB_SCRIPT%"
echo }else{ if($i.LastWriteTime -gt $outT){$need=$true} } >> "%RB_SCRIPT%"
echo if($need){break} >> "%RB_SCRIPT%"
echo } >> "%RB_SCRIPT%"
echo if($need){Write-Output 0}else{Write-Output 1} >> "%RB_SCRIPT%"
set "RB_RESULT="
for /f "usebackq delims=" %%r in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RB_SCRIPT%" 2^>nul`) do set "RB_RESULT=%%r"
del "%RB_SCRIPT%" 2>nul
if "!RB_RESULT!"=="1" exit /b 1
exit /b 0

:need_rebuild_shallow
REM Like :need_rebuild but directory scans are non-recursive (top-level files only).
set "RB_OUT=%~1"
if not exist "%RB_OUT%" exit /b 0
set "RB_SRCS="
set "RB_EXCLS="
:rbs_loop
shift
if "%~1"=="" goto :rbs_eval
set "RB_SRCS=!RB_SRCS!,'%~1'"
goto :rbs_loop
:rbs_eval
set "RB_SCRIPT=%TEMP%\zen_need_rebuild_%RANDOM%.ps1"
echo $out='!RB_OUT!' > "%RB_SCRIPT%"
set "RB_SRCS_PS=@()"
if not "!RB_SRCS!"=="" set "RB_SRCS_PS=@(!RB_SRCS:~1!)"
echo $srcs=!RB_SRCS_PS! >> "%RB_SCRIPT%"
set "RB_EXCLS_PS=@()"
if not "!RB_EXCLS!"=="" set "RB_EXCLS_PS=@(!RB_EXCLS:~1!)"
echo $excls=!RB_EXCLS_PS! >> "%RB_SCRIPT%"
echo $exclFulls=@() >> "%RB_SCRIPT%"
echo foreach($e in $excls){ if(Test-Path -LiteralPath $e){ $exclFulls += (Get-Item -LiteralPath $e).FullName } } >> "%RB_SCRIPT%"
echo $outT=(Get-Item -LiteralPath $out).LastWriteTime >> "%RB_SCRIPT%"
echo $need=$false >> "%RB_SCRIPT%"
echo foreach($s in $srcs){ >> "%RB_SCRIPT%"
echo if(-not(Test-Path -LiteralPath $s)){$need=$true;break} >> "%RB_SCRIPT%"
echo $i=Get-Item -LiteralPath $s >> "%RB_SCRIPT%"
echo if($i.PSIsContainer){ >> "%RB_SCRIPT%"
echo foreach($f in (Get-ChildItem -LiteralPath $s -File -ErrorAction SilentlyContinue)){ >> "%RB_SCRIPT%"
echo if(-not $f.Name.StartsWith('.') -and $f.LastWriteTime -gt $outT){$need=$true;break} >> "%RB_SCRIPT%"
echo } >> "%RB_SCRIPT%"
echo }else{ if($i.LastWriteTime -gt $outT){$need=$true} } >> "%RB_SCRIPT%"
echo if($need){break} >> "%RB_SCRIPT%"
echo } >> "%RB_SCRIPT%"
echo if($need){Write-Output 0}else{Write-Output 1} >> "%RB_SCRIPT%"
set "RB_RESULT="
for /f "usebackq delims=" %%r in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%RB_SCRIPT%" 2^>nul`) do set "RB_RESULT=%%r"
del "%RB_SCRIPT%" 2>nul
if "!RB_RESULT!"=="1" exit /b 1
exit /b 0

:prepare_desktop_staging
if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package
    echo [ERROR] Please place the pre-built WASM package in applications\dist\wasm32-unknown-unknown\%PROFILE%\pkg\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_HTML%" (
    echo [ERROR] Missing license HTML
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_JS%" (
    echo [ERROR] Missing license JS
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%ZEN_ERR_JS%" (
    echo [ERROR] Missing %ZEN_ERR_JS%
    echo [ERROR] Please run src/build.bat html first
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

copy /Y "%DIST_ROOT%\common\%LIC_HTML%" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\%LIC_JS%" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\%MANUAL_HTML%" "%DESKTOP_APP_DIR%\" >nul

exit /b 0



:build_desktop

set "DESKTOP_TARGET=%TARGET_X86_64%"

set "HELPER_NAME=zen_auth_helper.exe"

set "HELPER_SRC=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\%HELPER_NAME%"

set "DESKTOP_OUT=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe"

REM Incremental build: skip if nothing changed since last build.
REM Desktop/Replay embed Helper+WASM via go:embed; check union of their source dirs.
REM docs\ and LICENSE.md are already checked by the HTML build step.
if exist "!HELPER_SRC!" (
    call :need_rebuild_shallow "!DESKTOP_OUT!" "%DESKTOP_APP_DIR%"
    if !ERRORLEVEL! EQU 1 (
        call :need_rebuild "!DESKTOP_OUT!" "%DESKTOP_CORE_WEB%" "%DESKTOP_CORE_GO%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg\%WASM_LIB_NAME%" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\common\%MANUAL_HTML%" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock"
        if !ERRORLEVEL! EQU 1 (
            echo [INFO] Skipping Desktop ^(up-to-date^): !DESKTOP_OUT!
            exit /b 0
        )
    )
)

echo.

echo ============================================================

echo   Building zen_desktop (%PROFILE%) for %TARGET_X86_64%

echo ============================================================

call :prepare_desktop_staging

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

REM Release mode: hide Windows console window
if /I "%PROFILE%"=="release" set "LDFLAGS=%LDFLAGS% -H windowsgui"

if /I "%PROFILE%"=="release" (
    REM Use PowerShell: certutil's multi-line output + case-sensitive findstr
    REM would otherwise capture "SHA256" (the header line's first token) or just
    REM the first 2-char byte pair. PowerShell gives a single 64-char hex line.
    for /f "usebackq delims=" %%h in (`powershell -NoProfile -Command "Write-Output ((Get-FileHash -Algorithm SHA256 '%DESKTOP_APP_DIR%\%HELPER_NAME%').Hash.ToLower())"`) do (
        if not defined HELPER_SHA256 set "HELPER_SHA256=%%h"
    )
    if defined HELPER_SHA256 (
        set "LDFLAGS=!LDFLAGS! -X main.expectedHelperSHA256=!HELPER_SHA256!"
        echo   helper SHA-256: !HELPER_SHA256!
    ) else (
        echo [WARN] Failed to compute helper SHA-256, skipping runtime helper integrity check ^(not recommended^).
    )
)

echo -- Compiling Go desktop app...

REM Kill any running zen_desktop.exe so go build can overwrite the output file.
REM On Windows, a running .exe locks the file, preventing go build from
REM writing the new binary ("The process cannot access the file").
taskkill /F /IM zen_desktop.exe >nul 2>&1

REM Preserve user-owned files (license key / watchlist) across clean.
set "OUT_DIR=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop"
call :safe_clean_dir "!OUT_DIR!"

cd /d "%DESKTOP_APP_DIR%"

REM Replace __ZEN_DEBUG__ placeholder in zen.html (debug=true, release=false)
REM CRITICAL: Must use -Encoding UTF8 on both Get-Content and Set-Content to
REM preserve UTF-8 encoding. Without -Encoding UTF8, PowerShell 5.x defaults
REM to ANSI/UTF-16, which corrupts all multibyte (Chinese) characters.
if exist "zen.html" (
    if /I "%PROFILE%"=="debug" (
        powershell -NoProfile -Command "$c = Get-Content 'zen.html' -Raw -Encoding UTF8; $c = $c -replace '\"__ZEN_DEBUG__\"', '\"true\"'; [System.IO.File]::WriteAllText('zen.html', $c, (New-Object System.Text.UTF8Encoding $false))"
    ) else (
        powershell -NoProfile -Command "$c = Get-Content 'zen.html' -Raw -Encoding UTF8; $c = $c -replace '\"__ZEN_DEBUG__\"', '\"false\"'; [System.IO.File]::WriteAllText('zen.html', $c, (New-Object System.Text.UTF8Encoding $false))"
    )
)

go build -buildvcs=false %GO_TRIMPATH% -ldflags "%LDFLAGS%" -o "..\..\dist\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe" .

set "GO_ERR=!ERRORLEVEL!"

cd /d "%~dp0"

if !GO_ERR! neq 0 (

    echo [ERROR] Go desktop build failed

    call :cleanup_desktop_staging

    exit /b 1

)

echo [INFO] Desktop:  %DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe

exit /b 0



REM ==================== Replay HTML JS Obfuscation ====================
REM Obfuscate inline JavaScript in replay.html for release builds.
REM Uses javascript-obfuscator (same tool as WASM JS glue code obfuscation).
REM Backup is created before obfuscation and restored after Go build.

:obfuscate_replay_html

set "REPLAY_HTML=%REPLAY_APP_DIR%\replay.html"

if not exist "%REPLAY_HTML%" (
    echo [ERROR] replay.html not found for obfuscation
    exit /b 1
)

REM Only obfuscate in release mode
if /I not "%PROFILE%"=="release" exit /b 0

REM Find javascript-obfuscator module
set "OBF_MODULE="
for /f "usebackq delims=" %%p in (`npm root -g 2^>nul`) do (
    if exist "%%p\javascript-obfuscator" set "OBF_MODULE=%%p\javascript-obfuscator"
)
if not defined OBF_MODULE (
    for %%p in (
        "C:\Users\!USERNAME!\AppData\Roaming\npm\node_modules\javascript-obfuscator"
        "C:\Program Files\nodejs\node_modules\javascript-obfuscator"
    ) do (
        if exist "%%~p" set "OBF_MODULE=%%~p"
    )
)

if not defined OBF_MODULE (
    echo [WARN] javascript-obfuscator not found, skipping replay.html JS obfuscation
    echo [WARN] Install with: npm install -g javascript-obfuscator
    exit /b 0
)

REM Backup original
copy /Y "%REPLAY_HTML%" "%REPLAY_HTML%.bak" >nul

REM Create temporary obfuscation script
set "OBF_SCRIPT=%TEMP%\zen_replay_obf_%RANDOM%.js"

REM Disable delayed expansion so '!' in JS (!==, !jsContent) is output literally.
REM Inside the ( ) block we must escape: ( ^) ^< ^> and regex ^ as ^^
setlocal disabledelayedexpansion
(
echo const fs = require^('fs'^);
echo const { obfuscate } = require^(process.argv[3]^);
echo const htmlFile = process.argv[2];
echo const html = fs.readFileSync^(htmlFile, 'utf8'^);
echo const scriptRegex = /^<script^(?![^^^>]*\bsrc=^)[^^^>]*^>^([\s\S]*?^)^<\/script^>/gi;
echo let match;
echo let modified = html;
echo let count = 0;
echo while ^(^(match = scriptRegex.exec^(html^)^) !== null^) {
echo     const fullMatch = match[0];
echo     const jsContent = match[1];
echo     if ^(!jsContent.trim^(^)^) continue;
echo     const result = obfuscate^(jsContent, {compact:true, controlFlowFlattening:true, controlFlowFlatteningThreshold:0.75, deadCodeInjection:true, deadCodeInjectionThreshold:0.4, stringArray:true, stringArrayThreshold:0.8, unicodeEscapeSequence:true, selfDefending:true}^);
echo     const newScript = fullMatch.replace^(jsContent, result.getObfuscatedCode^(^)^);
echo     modified = modified.replace^(fullMatch, newScript^);
echo     count++;
echo }
echo fs.writeFileSync^(htmlFile, modified^);
echo console.log^('Obfuscated ' + count + ' inline script^(s^) in ' + htmlFile^);
) > "%OBF_SCRIPT%"
endlocal

node "%OBF_SCRIPT%" "%REPLAY_HTML%" "%OBF_MODULE%"
set "OBF_ERR=!ERRORLEVEL!"
del /f /q "%OBF_SCRIPT%" 2>nul

if !OBF_ERR! neq 0 (
    echo [WARN] replay.html JS obfuscation failed, restoring original
    copy /Y "%REPLAY_HTML%.bak" "%REPLAY_HTML%" >nul
    exit /b 0
)

echo [INFO] replay.html JS obfuscation complete
exit /b 0


:restore_replay_html

set "REPLAY_HTML=%REPLAY_APP_DIR%\replay.html"

if exist "%REPLAY_HTML%.bak" (
    copy /Y "%REPLAY_HTML%.bak" "%REPLAY_HTML%" >nul
    del /f /q "%REPLAY_HTML%.bak" 2>nul
)

exit /b 0



:cleanup_replay_staging
REM Clean zen_replay/app/ build artifacts (temp files copied from dist/common/)
REM Note: these files are in .gitignore, should not be tracked by git
REM If git reports deleted, file was mistakenly committed, run git rm --cached

if exist "%REPLAY_APP_DIR%\pkg" rd /s /q "%REPLAY_APP_DIR%\pkg"

mkdir "%REPLAY_APP_DIR%\pkg" >nul 2>nul

type NUL > "%REPLAY_APP_DIR%\pkg\placeholder.txt" 2>nul

for %%f in (
    zen_auth_helper
    zen_auth_helper.exe
    !LIC_HTML!
    !LIC_JS!
    !ZEN_ERR_JS!
    replay.html.bak
) do (
    if exist "%REPLAY_APP_DIR%\%%f" (
        powershell -NoProfile -Command "Remove-Item -Path '%REPLAY_APP_DIR%\%%f' -Force -ErrorAction SilentlyContinue"
    )
)

REM Recreate empty placeholders for go:embed IDE compatibility
REM (build script overwrites with real files before go build; cleanup restores empties)
type NUL > "%REPLAY_APP_DIR%\!LIC_HTML!" 2>nul
type NUL > "%REPLAY_APP_DIR%\!LIC_JS!" 2>nul
type NUL > "%REPLAY_APP_DIR%\!ZEN_ERR_JS!" 2>nul
type NUL > "%REPLAY_APP_DIR%\zen_auth_helper" 2>nul

REM 删除本地手动 go build 残留的游离二进制（非构建脚本产物）
if exist "%REPLAY_APP_DIR%\zen_replay" del /f /q "%REPLAY_APP_DIR%\zen_replay" 2>nul
if exist "%REPLAY_APP_DIR%\zen_replay.exe" del /f /q "%REPLAY_APP_DIR%\zen_replay.exe" 2>nul

exit /b 0



:prepare_replay_staging
if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package
    echo [ERROR] Please place the pre-built WASM package in applications\dist\wasm32-unknown-unknown\%PROFILE%\pkg\
    exit /b 1
)
call :cleanup_replay_staging

xcopy /E /I /Y /Q "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%REPLAY_APP_DIR%\pkg\" >nul

exit /b 0



:build_replay

set "REPLAY_TARGET=%TARGET_X86_64%"

set "HELPER_NAME=zen_auth_helper.exe"

set "HELPER_SRC=%DIST_ROOT%\%REPLAY_TARGET%\%PROFILE%\%HELPER_NAME%"

set "REPLAY_OUT=%DIST_ROOT%\%REPLAY_TARGET%\%PROFILE%\zen_replay\zen_replay.exe"

REM Incremental build: skip if nothing changed since last build.
REM Desktop/Replay embed Helper+WASM via go:embed; check union of their source dirs.
REM docs\ and LICENSE.md are already checked by the HTML build step.
if exist "!HELPER_SRC!" (
    call :need_rebuild_shallow "!REPLAY_OUT!" "%REPLAY_APP_DIR%"
    if !ERRORLEVEL! EQU 1 (
        call :need_rebuild "!REPLAY_OUT!" "%DESKTOP_CORE_WEB%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg\%WASM_LIB_NAME%" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock"
        if !ERRORLEVEL! EQU 1 (
            echo [INFO] Skipping Replay ^(up-to-date^): !REPLAY_OUT!
            exit /b 0
        )
    )
)

echo.

echo ============================================================

echo   Building zen_replay (%PROFILE%) for %TARGET_X86_64%

echo ============================================================

call :prepare_replay_staging

if not exist "!HELPER_SRC!" (
    echo [ERROR] Missing helper binary in !HELPER_SRC!
    echo [ERROR] Please place the pre-built helper binary in applications\dist\%REPLAY_TARGET%\%PROFILE%\
    call :cleanup_replay_staging
    exit /b 1
)

copy /Y "!HELPER_SRC!" "%REPLAY_APP_DIR%\%HELPER_NAME%" >nul

REM Copy license agreement files BEFORE Go build (Go embed needs them at compile time)
copy /Y "%DIST_ROOT%\common\%LIC_HTML%" "%REPLAY_APP_DIR%\" >nul
copy /Y "%DIST_ROOT%\common\%LIC_JS%" "%REPLAY_APP_DIR%\" >nul
copy /Y "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%REPLAY_APP_DIR%\" >nul

set "BASE_FLAGS="
set "LDFLAGS=-s -w -X main._internalFlag=0 %BASE_FLAGS%"
if /I "%PROFILE%"=="debug" set "LDFLAGS=-X main._internalFlag=1 %BASE_FLAGS%"

REM Release: Windows hidden console window (-H windowsgui)
if /I "%PROFILE%"=="release" set "LDFLAGS=%LDFLAGS% -H windowsgui"

if /I "%PROFILE%"=="release" (
    for /f "usebackq delims=" %%h in (`powershell -NoProfile -Command "Write-Output ((Get-FileHash -Algorithm SHA256 '%REPLAY_APP_DIR%\%HELPER_NAME%').Hash.ToLower())"`) do (
        if not defined HELPER_SHA256 set "HELPER_SHA256=%%h"
    )
    if defined HELPER_SHA256 (
        set "LDFLAGS=!LDFLAGS! -X main.expectedHelperSHA256=!HELPER_SHA256!"
        echo   helper SHA-256: !HELPER_SHA256!
    ) else (
        echo [WARN] Failed to compute helper SHA-256, skipping integrity check.
    )
)

REM Obfuscate replay.html inline JS (release mode only)
REM Must happen BEFORE Go build so the embedded HTML has obfuscated JS
call :obfuscate_replay_html

echo -- Compiling Go replay app...

REM Kill any running zen_replay.exe so go build can overwrite the output file.
taskkill /F /IM zen_replay.exe >nul 2>&1

REM Replay binary goes into its own zen_replay output directory
set "OUT_DIR=%DIST_ROOT%\%REPLAY_TARGET%\%PROFILE%\zen_replay"
call :safe_clean_dir "!OUT_DIR!"

cd /d "%REPLAY_APP_DIR%"

go build -buildvcs=false %GO_TRIMPATH% -ldflags "%LDFLAGS%" -o "..\..\dist\%REPLAY_TARGET%\%PROFILE%\zen_replay\zen_replay.exe" .

set "GO_ERR=!ERRORLEVEL!"

cd /d "%~dp0"

REM Restore original replay.html (obfuscated version was embedded in Go binary)
call :restore_replay_html

if !GO_ERR! neq 0 (

    echo [ERROR] Go replay build failed

    call :cleanup_replay_staging

    exit /b 1

)

echo [INFO] Replay:   %DIST_ROOT%\%REPLAY_TARGET%\%PROFILE%\zen_replay\zen_replay.exe

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
if not exist "%DIST_ROOT%\common\%LIC_HTML%" (
    echo [ERROR] Missing license HTML
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_JS%" (
    echo [ERROR] Missing license JS
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%ZEN_ERR_JS%" (
    echo [ERROR] Missing %ZEN_ERR_JS%
    echo [ERROR] Please run src/build.bat html first
    exit /b 1
)

REM Incremental build: skip if nothing changed since last build.
REM APK uses WASM+AAR; check WASM source dirs + interface_android.
REM docs\ and LICENSE.md are already checked by the HTML build step.
REM Exclude app\src\main\assets: syncZenAssets writes there during the build
REM and cleanupZenSyncedAssets deletes files afterward, which would otherwise
REM always make app\src appear newer than the APK, defeating incremental builds.
set "APK_OUT=%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk"
call :need_rebuild --exclude "%ANDROID_DIR%\zen_mobile\app\src\main\assets" "!APK_OUT!" "%ANDROID_DIR%\web" "%DESKTOP_CORE_WEB%" "%ANDROID_DIR%\zen_mobile\app\src" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg\%WASM_LIB_NAME%" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_android_api.aar" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\interfaces\interface_android" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock"
if !ERRORLEVEL! EQU 1 (
    echo [INFO] Skipping APK ^(up-to-date^)
    exit /b 0
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
    if exist "%%~d\release\zen_replay" rd /s /q "%%~d\release\zen_replay"
    if exist "%%~d\debug\zen_replay" rd /s /q "%%~d\debug\zen_replay"
)

REM Gradle / Android intermediate outputs (regenerable, never checked in)
if exist "%ANDROID_DIR%\zen_mobile\app\build" rd /s /q "%ANDROID_DIR%\zen_mobile\app\build"
if exist "%ANDROID_DIR%\zen_mobile\build" rd /s /q "%ANDROID_DIR%\zen_mobile\build"
if exist "%ANDROID_DIR%\zen_mobile\.gradle" rd /s /q "%ANDROID_DIR%\zen_mobile\.gradle"
if exist "%ANDROID_DIR%\zen_mobile\.kotlin" rd /s /q "%ANDROID_DIR%\zen_mobile\.kotlin"
if exist "%ANDROID_DIR%\zen_mobile\.idea" rd /s /q "%ANDROID_DIR%\zen_mobile\.idea"

REM Gradle 同步到 app/libs/ 的 AAR 副本（regenerable，从未入库）
if exist "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api.aar" del /f /q "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api.aar" 2>nul
if exist "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api-sources.jar" del /f /q "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api-sources.jar" 2>nul

call :cleanup_desktop_staging

call :cleanup_replay_staging

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

    if /I "%MODE%"=="replay" (

        call :check_and_print "Replay"  "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_replay\zen_replay.exe"

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

        call :check_and_print "Replay"  "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_replay\zen_replay.exe"

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

echo   replay   Build zen_replay app only

echo   apk      Build zen_mobile APK only

echo   all      Build desktop + replay + apk

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

echo   replay:  go (https://go.dev/dl/)

echo   apk: java JDK 17+, android-sdk (https://developer.android.com/studio)

exit /b 0

