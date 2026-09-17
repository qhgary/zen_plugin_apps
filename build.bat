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
REM README Chinese alias in zip see root build.bat README_HTML_ZIP_CP
REM (Rendered artifact README.html is ASCII; zip renaming done in root build.bat).
set "README_CSS=README.css"

set "DESKTOP_APP_DIR=%CD%\zen_desktop\app"

set "DESKTOP_CORE_WEB=%CD%\HQChart"

set "DESKTOP_CORE_GO=%CD%\zen_desktop\core\go"

set "REPLAY_APP_DIR=%CD%\zen_replay\app"

set "ANDROID_DIR=%CD%\android"

set "DOCS_DIR=%CD%\..\docs"

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



:sync_release_into_readme
REM Sync RELEASE.md content into README.md download section before rendering.
REM If RELEASE.md doesn't exist, README.md is left untouched.
REM Uses hash comparison with line-ending normalization (CRLF/LF treated equal).
set "SYNC_README_FILE=%~dp0README.md"
set "SYNC_RELEASE_FILE=%~dp0RELEASE.md"

if not exist "!SYNC_RELEASE_FILE!" exit /b 0
if not exist "!SYNC_README_FILE!" exit /b 0

REM Use PowerShell to merge: find download section heading, replace until next "## " heading.
REM Write to temp file first, then only overwrite README.md if content actually changed
REM (avoids touching mtime/git diff when RELEASE.md is unchanged).
REM The writeback is LF + no BOM ([IO.File]::WriteAllText joins with [char]10 and
REM uses UTF-8 without BOM) so the git-tracked README.md keeps a stable encoding
REM instead of gaining a BOM + CRLF from PowerShell's Set-Content -Encoding UTF8.
set "SYNC_TMP=%TEMP%\zen_readme_sync_%RANDOM%.tmp"
powershell -NoProfile -Command "$r='!SYNC_README_FILE!'; $rel='!SYNC_RELEASE_FILE!'; $tmp='!SYNC_TMP!'; $lines=Get-Content $r -Encoding UTF8; $p='^## '+[char]0x7985+[char]0x4E2D+[char]0x770B+[char]0x7F20; $h=-1; for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match $p){$h=$i;break}}; if($h -lt 0){exit 5}; $n=-1; for($i=$h+1;$i -lt $lines.Count;$i++){if($lines[$i] -match '^## '){$n=$i;break}}; $f=if($h -gt 0){$lines[0..($h-1)]}else{@()}; $rl=Get-Content $rel -Encoding UTF8; $rem=if($n -ge 0){$lines[$n..($lines.Count-1)]}else{@()}; [System.IO.File]::WriteAllText($tmp, (($f+$rl+@('')+$rem) -join [char]10))"
if errorlevel 5 (
    echo [WARN] README.md: download section heading not found, skipping RELEASE.md sync
    del "!SYNC_TMP!" >nul 2>&1
    exit /b 0
)

REM Compare with line-ending normalization: strip CR before hashing so CRLF vs LF
REM does not cause false "different" results.
set "HASH_NEW="
set "HASH_OLD="
for /f "delims=" %%h in ('powershell -NoProfile -Command "$nh=(Get-Content '!SYNC_TMP!' -Raw -Encoding UTF8) -replace \"`r`n\",`n -replace \"`r\",`n; [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($nh))).Replace('-','').ToLower()"') do set "HASH_NEW=%%h"
for /f "delims=" %%h in ('powershell -NoProfile -Command "$oh=(Get-Content '!SYNC_README_FILE!' -Raw -Encoding UTF8) -replace \"`r`n\",`n -replace \"`r\",`n; [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($oh))).Replace('-','').ToLower()"') do set "HASH_OLD=%%h"
if "!HASH_NEW!"=="!HASH_OLD!" (
    del "!SYNC_TMP!" >nul 2>&1
    exit /b 0
)
echo [INFO] README.md: download section updated from RELEASE.md
move /y "!SYNC_TMP!" "!SYNC_README_FILE!" >nul 2>&1
exit /b 0


:render_readme
call :sync_release_into_readme
set "README_SRC=%~dp0%README_MD%"
REM Rendered artifact placed in dist\common\README.html (ASCII, same as manual.html).
REM Root build.bat do_all_zip copies it as Chinese alias inside zip.
set "README_DST=%CD%\dist\common\%README_HTML%"
set "CSS_SRC=%~dp0%README_CSS%"
set "QRCODE_DIR=%~dp0qrcode"
set "SHOT_DIR=%~dp0软件截图"
if not exist "%CD%\dist\common" mkdir "%CD%\dist\common" >nul 2>&1

REM Hand every path to the PowerShell steps below through the environment instead
REM of the command line. Windows PowerShell 5.1 mis-decodes UTF-8 command-line
REM arguments (the shot folder name is Chinese), which makes Test-Path fail and
REM silently skips the screenshot inlining. Environment variables are UTF-16 and
REM survive the trip intact.
set "ZEN_README_CSS=!CSS_SRC!"
set "ZEN_README_QR=!QRCODE_DIR!"
set "ZEN_README_SHOT=!SHOT_DIR!"
set "ZEN_README_SHOT_REL=软件截图/"
set "ZEN_README_DST=!README_DST!"

if not exist "!README_SRC!" (
    echo [WARN] %README_MD% not found, skipping readme render
    exit /b 0
)

where pandoc >nul 2>&1
if errorlevel 1 (
    echo [WARN] pandoc not found, skipping readme render
    exit /b 0
)

REM Skip render if README.html is already newer than README.md and README.css.
REM The stylesheet AND the screenshots are inlined below, so a CSS-only or
REM screenshot-only change must also trigger a re-render (mirrors
REM applications/build.sh). Freshness is decided in PowerShell because comparing
REM the locale-dependent %%~tA strings of a whole tree in batch is unreliable.
REM A README.html that still contains relative image references was produced by
REM an older renderer, so it is treated as stale regardless of its timestamp -
REM otherwise the gate would freeze the broken artifact forever.
set "README_STALE="
if exist "!README_DST!" (
    powershell -NoProfile -Command "$stale=$false; $dst=$env:ZEN_README_DST; $sd=$env:ZEN_README_SHOT; if (Test-Path -LiteralPath $sd) { $e='.png','.jpg','.jpeg'; $n=Get-ChildItem -LiteralPath $sd -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $e -contains $_.Extension.ToLower() } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1; if ($n -and $n.LastWriteTimeUtc -gt (Get-Item -LiteralPath $dst).LastWriteTimeUtc) { $stale=$true } }; $raw=Get-Content -LiteralPath $dst -Raw -Encoding UTF8 -ErrorAction SilentlyContinue; if ($raw) { if ($raw.Contains('qrcode/') -or $raw.Contains($env:ZEN_README_SHOT_REL)) { $stale=$true } }; if ($stale) { exit 1 }" >nul 2>&1
    if errorlevel 1 set "README_STALE=1"
)
if exist "!README_DST!" (
    for %%A in ("!README_SRC!") do set "MD_MTIME=%%~tA"
    for %%A in ("!README_DST!") do set "HTML_MTIME=%%~tA"
    if not exist "!CSS_SRC!" (
        if "!HTML_MTIME!" geq "!MD_MTIME!" if not defined README_STALE (
            echo [INFO] %README_HTML%: up-to-date
            exit /b 0
        )
    ) else (
        for %%A in ("!CSS_SRC!") do set "CSS_MTIME=%%~tA"
        if "!HTML_MTIME!" geq "!MD_MTIME!" if "!HTML_MTIME!" geq "!CSS_MTIME!" if not defined README_STALE (
            echo [INFO] %README_HTML%: up-to-date
            exit /b 0
        )
    )
)

echo [INFO] Rendering %README_MD% - %README_HTML%...
rem Render to a per-run temp file first so README.html is only replaced when
rem the rendered bytes actually differ (keeps mtime/git diff stable).
set "TEMP_HTML=%TEMP%\zen_readme_temp_%RANDOM%.html"
set "ZEN_README_TMP=!TEMP_HTML!"
pandoc -s -o "!TEMP_HTML!" "!README_SRC!" 2>nul
if errorlevel 1 (
    echo [WARN] Failed to render %README_HTML%
    del "!TEMP_HTML!" >nul 2>&1
    exit /b 0
)

rem Inject our CSS in place of pandoc's default <style>, then inline the
rem qrcode PNGs and every screenshot under 软件截图 as base64 data URIs so
rem README.html is a single self-contained file (matches applications\build.sh).
rem Written as UTF-8 without BOM.
REM NOTE: this -Command string must contain NO double quotes and NO non-ASCII
REM text. cmd.exe mangles `""` inside a quoted argument, and Windows PowerShell
REM 5.1 mis-decodes UTF-8 text on the command line (the Chinese screenshot
REM folder), either of which silently corrupts the literals below. So the quote
REM character is built with [char]34, every literal uses single quotes only, and
REM all paths are read from $env:ZEN_README_* instead of being passed as argv.
powershell -NoProfile -Command "$q=[char]34; $css=Get-Content -LiteralPath $env:ZEN_README_CSS -Raw -Encoding UTF8; $html=Get-Content -LiteralPath $env:ZEN_README_TMP -Raw -Encoding UTF8; $html=$html -replace '(?s)<style>.*?</style>', ('<style>'+$css+'</style>'); foreach ($im in 'alipay.png','qq.png') { $p=Join-Path $env:ZEN_README_QR $im; if (Test-Path -LiteralPath $p) { $uri='data:image/png;base64,'+[Convert]::ToBase64String([IO.File]::ReadAllBytes($p)); $html=$html.Replace('src='+$q+'qrcode/'+$im+$q,'src='+$q+$uri+$q).Replace('src=qrcode/'+$im,'src='+$q+$uri+$q) } }; $sd=$env:ZEN_README_SHOT; if (Test-Path -LiteralPath $sd) { $base=Split-Path -Parent $sd; $bl=$base.TrimEnd('\','/').Length; $e='.png','.jpg','.jpeg'; Get-ChildItem -LiteralPath $sd -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $e -contains $_.Extension.ToLower() } | ForEach-Object { $rl=($_.FullName.Substring($bl+1)) -replace '\\','/'; $mt=@{'.png'='png';'.jpg'='jpeg';'.jpeg'='jpeg'}[$_.Extension.ToLower()]; $uri='data:image/'+$mt+';base64,'+[Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)); $html=$html.Replace('src='+$q+$rl+$q,'src='+$q+$uri+$q).Replace('src='+$rl,'src='+$q+$uri+$q) } }; [System.IO.File]::WriteAllText($env:ZEN_README_TMP,$html,(New-Object System.Text.UTF8Encoding $false))"
if errorlevel 1 (
    echo [WARN] Failed to inject CSS and inline images into %README_HTML%
    del "!TEMP_HTML!" >nul 2>&1
    exit /b 0
)

rem Only replace README.html when its byte content actually changed.
if exist "!README_DST!" (
    fc /b "!TEMP_HTML!" "!README_DST!" >nul 2>&1
    if not errorlevel 1 (
        del "!TEMP_HTML!" >nul 2>&1
        echo [INFO] %README_HTML%: up-to-date
        exit /b 0
    )
)
move /y "!TEMP_HTML!" "!README_DST!" >nul 2>&1

echo [INFO] %README_HTML%: !README_DST!
exit /b 0



:mode_desktop
call :render_readme
call :check_go_tools || exit /b 1
call :build_desktop || exit /b 1
call :clean_dist_intermediates
call :show_summary
exit /b 0



:mode_replay
call :render_readme
call :check_go_tools || exit /b 1
call :build_replay || exit /b 1
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

if exist "%DESKTOP_APP_DIR%\jscommon" rd /s /q "%DESKTOP_APP_DIR%\jscommon"
if exist "%DESKTOP_APP_DIR%\pkg" rd /s /q "%DESKTOP_APP_DIR%\pkg"
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
    if exist "%DESKTOP_APP_DIR%\%%f" del /f /q "%DESKTOP_APP_DIR%\%%f" 2>nul
)

REM Recreate empty placeholders for go:embed IDE compatibility
REM (build script overwrites with real files before go build; cleanup restores empties)
type NUL > "%DESKTOP_APP_DIR%\ZenChartDraw.js" 2>nul
type NUL > "%DESKTOP_APP_DIR%\ZenHQChartCompat.js" 2>nul
type NUL > "%DESKTOP_APP_DIR%\%LIC_HTML%" 2>nul
type NUL > "%DESKTOP_APP_DIR%\%LIC_JS%" 2>nul
type NUL > "%DESKTOP_APP_DIR%\%ZEN_ERR_JS%" 2>nul
type NUL > "%DESKTOP_APP_DIR%\zen_auth_helper" 2>nul

REM Clean leftover binaries from manual go build (not script outputs)
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
REM Incremental build check via content snapshots (fc /b compare; immune to
REM mtime drift, no robocopy /L mtime+size false positives).
REM Usage: call :need_rebuild "snap_name" "output" [--exclude "dir"] "src1" "src2" ...
REM Sources may be dirs (recursive) or files. Additions, modifications and
REM deletions all trigger a rebuild. Snapshots live under %TEMP%\zen_build_snap\
REM and are refreshed by :snap_update after each successful build.
REM Returns: errorlevel 0 = need rebuild, 1 = can skip.
if not defined SNAP_ROOT set "SNAP_ROOT=%TEMP%\zen_build_snap\zen_plugin_apps"
set "RB_NEED=0"
set "RB_SNAP="
set "RB_OUT="
set "RB_XDP="
set "RB_SRC_COUNT=0"
:nr_parse
if "%~1"=="" goto :nr_eval
if /I "%~1"=="--exclude" goto :nr_handle_exclude
if not defined RB_SNAP (
    set "RB_SNAP=!SNAP_ROOT!\%~1"
) else if not defined RB_OUT (
    set "RB_OUT=%~1"
    if not exist "!RB_OUT!" (
        set "RB_NEED=1"
    )
    if not exist "!RB_SNAP!\" (
        set "RB_NEED=1"
    )
) else if "!RB_NEED!"=="0" (
    set /a RB_SRC_COUNT+=1
    call :nr_snap_check "!RB_SNAP!" "%~1"
)
shift
goto :nr_parse

:nr_handle_exclude
REM Collect excluded dirs as ';'-separated ABSOLUTE paths (RB_XDP) outside any
REM compound statement to avoid the %~2 expansion pitfall. :nr_check_dir_deep
REM translates them into relative prefixes so build-time scratch dirs (e.g.
REM app\src\main\assets) never defeat the gate.
shift
set "RB_XDP=!RB_XDP!;%~2"
shift
goto :nr_parse

:nr_eval
if "!RB_NEED!"=="1" exit /b 0
exit /b 1

:nr_snap_check
REM %1 = snapshot dir, %2 = source (dir or file). Sets RB_NEED=1 on change.
set "SC_SNAP=%~1"
set "SC_SRC=%~2"
if not exist "!SC_SRC!" (
    set "RB_NEED=1"
    exit /b 0
)
REM Use PowerShell Get-Item.PSIsContainer to reliably detect directories.
REM if exist "path\" returns TRUE for files on UNC/network paths (cmd.exe bug).
REM dir /a /b /ad also fails on UNC paths (returns empty in for /f loops).
set "_is_dir=0"
for /f %%i in ('powershell -NoProfile -Command "(Get-Item -LiteralPath '!SC_SRC!' -ErrorAction SilentlyContinue).PSIsContainer" 2^>nul') do (
    if "%%i"=="True" set "_is_dir=1"
)
if "!_is_dir!"=="1" goto :nr_check_dir
if not exist "!SC_SNAP!\%~nx2" (
    set "RB_NEED=1"
    exit /b 0
)
fc /b "!SC_SRC!" "!SC_SNAP!\%~nx2" >nul 2>&1
if not errorlevel 1 exit /b 0
set "RB_NEED=1"
exit /b 0
:nr_check_dir
REM Byte-content directory comparison (replaces the robocopy /E /L mtime+size
REM check, which triggered false rebuilds on mtime drift e.g. git checkout).
if not exist "!SC_SNAP!\%~nx2\" (
    set "RB_NEED=1"
    exit /b 0
)
call :nr_check_dir_deep "!SC_SRC!" "!SC_SNAP!\%~nx2"
exit /b 0

:nr_check_dir_deep
REM Recursive byte-content directory comparison.
REM %1 = source dir, %2 = snapshot dir. Sets RB_NEED=1 on any difference.
REM Files under RB_XDP excluded dirs (absolute paths, ';'-separated) are
REM skipped on both sides, so build-time scratch dirs never defeat the gate.
REM dir /s /b always emits ABSOLUTE paths, so the relative-path extraction
REM below must strip an ABSOLUTE base. Normalize the source base first -
REM otherwise the leftover drive prefix breaks every snapshot lookup and the
REM gate never skips.
set "RBD_SRC=%~1"
set "RBD_SNAP=%~2"
for %%i in ("!RBD_SRC!") do set "RBD_SRC=%%~fi"
REM Also strip a trailing backslash from the snapshot base: if RBD_SNAP ends
REM with "\", the substitution below eats RELF's leading "\" as well, so
REM "!RBD_SNAP!!RBD_RELF!" concatenates into "authmod.rs"-style paths that
REM never exist - flagging every comparison as a deletion and keeping the
REM gate in a permanent rebuild loop.
for %%i in ("!RBD_SNAP!") do set "RBD_SNAP=%%~fi"
REM Translate excluded dirs located under the source dir into relative
REM prefixes (e.g. \main\assets) so the per-file skip test works on the
REM RELF paths produced below.
set "RBD_XDR="
if defined RB_XDP for %%x in ("!RB_XDP:;=" "!") do (
    if not "%%~x"=="" (
        for %%i in ("%%~x") do set "RBD_XDA=%%~fi"
        set "RBD_XDT=!RBD_XDA!"
        set "RBD_XDT=!RBD_XDT:%RBD_SRC%=!"
        if not "!RBD_XDT!"=="!RBD_XDA!" set "RBD_XDR=!RBD_XDR!;!RBD_XDT!"
    )
)
REM Check files in source vs snapshot (detects additions + content changes).
REM dir /s already recurses into subdirectories, so this one pass covers the
REM whole tree.
for /f "delims=" %%f in ('dir /s /b /a-d "!RBD_SRC!" 2^>nul') do (
    if "!RB_NEED!"=="0" (
        set "RBD_RELF=%%f"
        set "RBD_RELF=!RBD_RELF:%RBD_SRC%=!"
        set "RBD_SKIP=0"
        if defined RBD_XDR for %%x in ("!RBD_XDR:;=" "!") do (
            if not "%%~x"=="" (
                set "RBD_CHK=!RBD_RELF!"
                set "RBD_CHK=!RBD_CHK:%%~x\=!"
                if not "!RBD_CHK!"=="!RBD_RELF!" set "RBD_SKIP=1"
            )
        )
        if "!RBD_SKIP!"=="0" (
            if not exist "!RBD_SNAP!!RBD_RELF!" (
                set "RB_NEED=1"
            ) else (
                fc /b "%%f" "!RBD_SNAP!!RBD_RELF!" >nul 2>&1
                if errorlevel 1 set "RB_NEED=1"
            )
        )
    )
)
REM Check for files in snapshot but not in source (deletions)
if "!RB_NEED!"=="0" (
    for /f "delims=" %%f in ('dir /s /b /a-d "!RBD_SNAP!" 2^>nul') do (
        if "!RB_NEED!"=="0" (
            set "RBD_RELF=%%f"
            set "RBD_RELF=!RBD_RELF:%RBD_SNAP%=!"
            set "RBD_SKIP=0"
            if defined RBD_XDR for %%x in ("!RBD_XDR:;=" "!") do (
                if not "%%~x"=="" (
                    set "RBD_CHK=!RBD_RELF!"
                    set "RBD_CHK=!RBD_CHK:%%~x\=!"
                    if not "!RBD_CHK!"=="!RBD_RELF!" set "RBD_SKIP=1"
                )
            )
            if "!RBD_SKIP!"=="0" (
                if not exist "!RBD_SRC!!RBD_RELF!" set "RB_NEED=1"
            )
        )
    )
)
exit /b 0

:snap_update
REM Refresh the snapshot for a successfully built output.
REM Usage: call :snap_update "snap_name" [--exclude "dir"] "src1" "src2" ...
if not defined SNAP_ROOT set "SNAP_ROOT=%TEMP%\zen_build_snap\zen_plugin_apps"
set "SU_SNAP=!SNAP_ROOT!\%~1"
set "SU_XD="
if not exist "!SU_SNAP!\" mkdir "!SU_SNAP!\" >nul 2>&1
shift
:su_loop
if "%~1"=="" exit /b 0
if /I "%~1"=="--exclude" (
    shift
    set "SU_XD=!SU_XD! /XD %~2"
    shift
    goto :su_loop
)
call :nr_snap_mirror "!SU_SNAP!" "%~1"
shift
goto :su_loop

:nr_snap_mirror
set "SC_SNAP=%~1"
set "SC_SRC=%~2"
if not exist "!SC_SRC!" (
    if exist "!SC_SNAP!\%~nx2\" rd /s /q "!SC_SNAP!\%~nx2"
    if exist "!SC_SNAP!\%~nx2" del /f /q "!SC_SNAP!\%~nx2"
    exit /b 0
)
REM Use PowerShell Get-Item.PSIsContainer to reliably detect directories.
REM if exist "path\" returns TRUE for files on UNC/network paths (cmd.exe bug).
REM dir /a /b /ad also fails on UNC paths (returns empty in for /f loops).
set "_is_dir=0"
for /f %%i in ('powershell -NoProfile -Command "(Get-Item -LiteralPath '!SC_SRC!' -ErrorAction SilentlyContinue).PSIsContainer" 2^>nul') do (
    if "%%i"=="True" set "_is_dir=1"
)
if "!_is_dir!"=="1" (
    robocopy "!SC_SRC!" "!SC_SNAP!\%~nx2" /MIR !SU_XD! /NFL /NDL /NJH /NJS /NP >nul 2>&1
) else (
    copy /y "!SC_SRC!" "!SC_SNAP!\%~nx2" >nul 2>&1
)
exit /b 0

:prepare_desktop_staging
if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package
    echo [ERROR] Please place the pre-built WASM package in applications\dist\wasm32-unknown-unknown\%PROFILE%\pkg\
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_HTML%" (
    echo [ERROR] Missing license HTML
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_JS%" (
    echo [ERROR] Missing license JS
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%ZEN_ERR_JS%" (
    echo [ERROR] Missing %ZEN_ERR_JS%
    echo [ERROR] Please run src/build.bat html first
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
    exit /b 1
)
call :cleanup_desktop_staging

echo [INFO] Packing closed-source deps: helper ^(%TARGET_X86_64%^), wasm ^(%TARGET_WASM%^), html

xcopy /E /I /Y "%DESKTOP_CORE_WEB%\jscommon" "%DESKTOP_APP_DIR%\jscommon\" >nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.testdata*" 2>nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.NetworkFilterTest.js" 2>nul

del /Q "%DESKTOP_APP_DIR%\jscommon\umychart.regressiontest.js" 2>nul

copy /Y "%DESKTOP_CORE_WEB%\ZenHQChartCompat.js" "%DESKTOP_APP_DIR%\" >nul
set "CP_ERR=!ERRORLEVEL!"
for %%f in ("%DESKTOP_APP_DIR%\ZenHQChartCompat.js") do set "CP_SIZE=%%~zf"

copy /Y "%DESKTOP_CORE_WEB%\ZenChartDraw.js" "%DESKTOP_APP_DIR%\" >nul
set "CP_ERR=!ERRORLEVEL!"
for %%f in ("%DESKTOP_APP_DIR%\ZenChartDraw.js") do set "CP_SIZE=%%~zf"

xcopy /E /I /Y "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DESKTOP_APP_DIR%\pkg\" >nul

copy /Y "%DIST_ROOT%\common\%LIC_HTML%" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\%LIC_JS%" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DESKTOP_APP_DIR%\" >nul

copy /Y "%DIST_ROOT%\common\%MANUAL_HTML%" "%DESKTOP_APP_DIR%\" >nul

REM Copy UI version source BEFORE Go build (Go embed needs the file at compile time)
xcopy /Y "%~dp0VERSION" "%DESKTOP_APP_DIR%\" >nul

exit /b 0



:build_desktop

set "DESKTOP_TARGET=%TARGET_X86_64%"

set "HELPER_NAME=zen_auth_helper.exe"

set "HELPER_SRC=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\%HELPER_NAME%"

set "DESKTOP_OUT=%DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe"

REM Incremental build: skip if nothing changed since last build.
REM Desktop/Replay embed Helper+WASM via go:embed; check union of their source dirs.
REM docs\ and LICENSE.md are already checked by the HTML build step.
REM go:embed covers zen.html/JS/jscommon/pkg/lic/helper - all inputs checked.
call :need_rebuild "desktop_%PROFILE%" "!DESKTOP_OUT!" "%DESKTOP_APP_DIR%\zen.html" "%DESKTOP_APP_DIR%\ZenLocalService.js" "%DESKTOP_APP_DIR%\StockData.js" "%DESKTOP_APP_DIR%\zen_analysis_worker.js" "%DESKTOP_APP_DIR%\ZenChartDraw.js" "%DESKTOP_APP_DIR%\ZenHQChartCompat.js" "%DESKTOP_APP_DIR%\ZenStockSearch.js" "%DESKTOP_APP_DIR%\zen_error_codes.js" "%DESKTOP_APP_DIR%\main.go" "%DESKTOP_APP_DIR%\helper_embed_darwin.go" "%DESKTOP_APP_DIR%\helper_embed_windows.go" "%DESKTOP_APP_DIR%\helper_proc_unix.go" "%DESKTOP_APP_DIR%\helper_proc_windows.go" "%DESKTOP_APP_DIR%\go.mod" "%DESKTOP_APP_DIR%\go.sum" "%DESKTOP_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "%DESKTOP_CORE_GO%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\common\%MANUAL_HTML%" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\contact.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock" "%~dp0VERSION"
if !ERRORLEVEL! NEQ 1 goto :desktop_needs_build
echo [INFO] Skipping Desktop ^(up-to-date^): !DESKTOP_OUT!
echo result=skipped> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
exit /b 0
:desktop_needs_build

echo.

echo ============================================================

echo   Building zen_desktop (%PROFILE%) for %TARGET_X86_64%

echo ============================================================

call :prepare_desktop_staging

if not exist "!HELPER_SRC!" (
    echo [ERROR] Missing helper binary in !HELPER_SRC!
    echo [ERROR] Please place the pre-built helper binary in applications\dist\%DESKTOP_TARGET%\%PROFILE%\
    call :cleanup_desktop_staging
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
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

REM Force GOOS=windows for the desktop build.
REM helper_embed_windows.go uses //go:build windows, so GOOS must be windows
REM or the file is skipped and main.go's embeddedHelper symbol becomes undefined.
REM A stale GOOS in the user shell (e.g. GOOS=darwin from a prior cross build)
REM would otherwise produce a confusing "undefined: embeddedHelper" compile error.
if /I not "%GOOS%"=="windows" (
    if defined GOOS (
        echo [WARN] GOOS=%GOOS% set in environment; overriding to windows for desktop build
    ) else (
        echo [INFO] GOOS unset; setting to windows for desktop build
    )
)
set "GOOS=windows"
set "GOARCH=amd64"

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

    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"

    exit /b 1

)

echo [INFO] Desktop:  %DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe

echo result=built> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"

REM Update snapshot so next build can detect up-to-date
call :snap_update "desktop_%PROFILE%" "%DESKTOP_APP_DIR%\zen.html" "%DESKTOP_APP_DIR%\ZenLocalService.js" "%DESKTOP_APP_DIR%\StockData.js" "%DESKTOP_APP_DIR%\zen_analysis_worker.js" "%DESKTOP_APP_DIR%\ZenChartDraw.js" "%DESKTOP_APP_DIR%\ZenHQChartCompat.js" "%DESKTOP_APP_DIR%\ZenStockSearch.js" "%DESKTOP_APP_DIR%\zen_error_codes.js" "%DESKTOP_APP_DIR%\main.go" "%DESKTOP_APP_DIR%\helper_embed_darwin.go" "%DESKTOP_APP_DIR%\helper_embed_windows.go" "%DESKTOP_APP_DIR%\helper_proc_unix.go" "%DESKTOP_APP_DIR%\helper_proc_windows.go" "%DESKTOP_APP_DIR%\go.mod" "%DESKTOP_APP_DIR%\go.sum" "%DESKTOP_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "%DESKTOP_CORE_GO%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\common\%MANUAL_HTML%" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\contact.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock" "%~dp0VERSION"

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
REM Obfuscation seed derived from crate version (deterministic per version).
REM Closed-source build (full monorepo): ..\Cargo.toml present -> use
REM version-encoded seed (reproducible across builds, ties obfuscation to engine
REM version). Standalone build (applications-only checkout, public repo): no
REM Cargo.toml -> use a per-build random seed and warn. Random seed is
REM intentional: without the closed-source engine there is no canonical version
REM to derive from, and a constant fallback would let any public-repo consumer
REM produce byte-identical obfuscated output across machines.
set "OBF_VER="
set "OBF_CARGO=%~dp0..\Cargo.toml"
set "SEED="
if not exist "%OBF_CARGO%" goto :obf_seed_random
REM Read the [package] version directly (first "version =" line). AVOID findstr:
REM it fails on Unix/LF-only files like Cargo.toml, and its output is ambiguous
REM when the file has dependency tables with their own "version =" keys (a last-
REM line-wins parse would grab "1.0" instead of the package "0.4.4"). First
REM match wins, mirroring grep -m1 in applications/build.sh.
for /f "usebackq tokens=1,* delims== " %%a in ("%OBF_CARGO%") do (
    if /I "%%a"=="version" if not defined OBF_VER set "OBF_VER=%%~b"
)
if defined OBF_VER for /f "tokens=1-3 delims=. " %%a in ("%OBF_VER%") do set /a "SEED=%%a * 1048576 + %%b * 1024 + %%c" 2>nul
if defined SEED goto :obf_seed_done
REM Cargo.toml exists but version is not a clean semver; fall through to random
echo [WARN] Cannot derive version-encoded seed from %OBF_CARGO% (got '%OBF_VER%')
:obf_seed_random
if not defined SEED (
    echo [WARN] Cargo.toml not found or unparseable at %OBF_CARGO% (standalone build); using per-build random seed
    set /a "SEED=!RANDOM! * 32768 + !RANDOM!"
)
:obf_seed_done
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
echo     const seed = parseInt^(process.argv[4],10^)^|^|0;
    echo     const result = obfuscate^(jsContent, {compact:true, controlFlowFlattening:true, controlFlowFlatteningThreshold:0.75, deadCodeInjection:true, deadCodeInjectionThreshold:0.4, stringArray:true, stringArrayThreshold:0.8, unicodeEscapeSequence:true, selfDefending:true, seed:seed}^);
echo     const newScript = fullMatch.replace^(jsContent, result.getObfuscatedCode^(^)^);
echo     modified = modified.replace^(fullMatch, newScript^);
echo     count++;
echo }
echo fs.writeFileSync^(htmlFile, modified^);
echo console.log^('Obfuscated ' + count + ' inline script^(s^) in ' + htmlFile^);
) > "%OBF_SCRIPT%"
endlocal

node "%OBF_SCRIPT%" "%REPLAY_HTML%" "%OBF_MODULE%" "%SEED%"
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
    if exist "%REPLAY_APP_DIR%\%%f" del /f /q "%REPLAY_APP_DIR%\%%f" 2>nul
)

REM Recreate empty placeholders for go:embed IDE compatibility
REM (build script overwrites with real files before go build; cleanup restores empties)
type NUL > "%REPLAY_APP_DIR%\%LIC_HTML%" 2>nul
type NUL > "%REPLAY_APP_DIR%\%LIC_JS%" 2>nul
type NUL > "%REPLAY_APP_DIR%\%ZEN_ERR_JS%" 2>nul
type NUL > "%REPLAY_APP_DIR%\zen_auth_helper" 2>nul

REM Clean leftover binaries from manual go build (not script outputs)
if exist "%REPLAY_APP_DIR%\zen_replay" del /f /q "%REPLAY_APP_DIR%\zen_replay" 2>nul
if exist "%REPLAY_APP_DIR%\zen_replay.exe" del /f /q "%REPLAY_APP_DIR%\zen_replay.exe" 2>nul

exit /b 0



:prepare_replay_staging
if not exist "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" (
    echo [ERROR] Missing WASM package
    echo [ERROR] Please place the pre-built WASM package in applications\dist\wasm32-unknown-unknown\%PROFILE%\pkg\
    echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"
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
call :need_rebuild "replay_%PROFILE%" "!REPLAY_OUT!" "%REPLAY_APP_DIR%\replay.html" "%REPLAY_APP_DIR%\main.go" "%REPLAY_APP_DIR%\helper_embed_darwin.go" "%REPLAY_APP_DIR%\helper_embed_windows.go" "%REPLAY_APP_DIR%\helper_proc_unix.go" "%REPLAY_APP_DIR%\helper_proc_windows.go" "%REPLAY_APP_DIR%\go.mod" "%REPLAY_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\contact.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock" "%~dp0VERSION"
if !ERRORLEVEL! NEQ 1 goto :replay_needs_build
echo [INFO] Skipping Replay ^(up-to-date^): !REPLAY_OUT!
echo result=skipped> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"
exit /b 0
:replay_needs_build

echo.

echo ============================================================

echo   Building zen_replay (%PROFILE%) for %TARGET_X86_64%

echo ============================================================

call :prepare_replay_staging

if not exist "!HELPER_SRC!" (
    echo [ERROR] Missing helper binary in !HELPER_SRC!
    echo [ERROR] Please place the pre-built helper binary in applications\dist\%REPLAY_TARGET%\%PROFILE%\
    call :cleanup_replay_staging
    echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"
    exit /b 1
)

copy /Y "!HELPER_SRC!" "%REPLAY_APP_DIR%\%HELPER_NAME%" >nul

REM Copy license agreement files BEFORE Go build (Go embed needs them at compile time)
copy /Y "%DIST_ROOT%\common\%LIC_HTML%" "%REPLAY_APP_DIR%\" >nul
copy /Y "%DIST_ROOT%\common\%LIC_JS%" "%REPLAY_APP_DIR%\" >nul
copy /Y "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%REPLAY_APP_DIR%\" >nul

REM Copy UI version source BEFORE Go build (Go embed needs the file at compile time)
xcopy /Y "%~dp0VERSION" "%REPLAY_APP_DIR%\" >nul

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

REM Force GOOS=windows for the replay build.
REM helper_embed_windows.go uses //go:build windows, so GOOS must be windows
REM or the file is skipped and main.go's embeddedHelper symbol becomes undefined.
REM A stale GOOS in the user shell (e.g. GOOS=darwin from a prior cross build)
REM would otherwise produce a confusing "undefined: embeddedHelper" compile error.
if /I not "%GOOS%"=="windows" (
    if defined GOOS (
        echo [WARN] GOOS=%GOOS% set in environment; overriding to windows for replay build
    ) else (
        echo [INFO] GOOS unset; setting to windows for replay build
    )
)
set "GOOS=windows"
set "GOARCH=amd64"

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

    echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"

    exit /b 1

)

echo [INFO] Replay:   %DIST_ROOT%\%REPLAY_TARGET%\%PROFILE%\zen_replay\zen_replay.exe

echo result=built> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"

REM Update snapshot so next build can detect up-to-date
call :snap_update "replay_%PROFILE%" "%REPLAY_APP_DIR%\replay.html" "%REPLAY_APP_DIR%\main.go" "%REPLAY_APP_DIR%\helper_embed_darwin.go" "%REPLAY_APP_DIR%\helper_embed_windows.go" "%REPLAY_APP_DIR%\helper_proc_unix.go" "%REPLAY_APP_DIR%\helper_proc_windows.go" "%REPLAY_APP_DIR%\go.mod" "%REPLAY_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\contact.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock" "%~dp0VERSION"

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
    echo result=failed> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_HTML%" (
    echo [ERROR] Missing license HTML
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    echo result=failed> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%LIC_JS%" (
    echo [ERROR] Missing license JS
    echo [ERROR] Please place the pre-built license files in applications\dist\common\
    echo result=failed> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 1
)
if not exist "%DIST_ROOT%\common\%ZEN_ERR_JS%" (
    echo [ERROR] Missing %ZEN_ERR_JS%
    echo [ERROR] Please run src/build.bat html first
    echo result=failed> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 1
)

REM Incremental build: skip if nothing changed since last build.
REM APK uses WASM+AAR; check WASM source dirs + interface_android.
REM docs\ and LICENSE.md are already checked by the HTML build step.
REM Exclude app\src\main\assets: syncZenAssets writes there during the build
REM and cleanupZenSyncedAssets deletes files afterward, which would otherwise
REM always make app\src appear newer than the APK, defeating incremental builds.
set "APK_OUT=%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk"
call :need_rebuild "apk_%PROFILE%" --exclude "%ANDROID_DIR%\zen_mobile\app\src\main\assets" "!APK_OUT!" "%ANDROID_DIR%\zen_mobile\frontend" "%DESKTOP_CORE_WEB%" "%ANDROID_DIR%\zen_mobile\app\src" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_android_api.aar" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\contact.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\interfaces\interface_android" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock" "%~dp0VERSION"
if !ERRORLEVEL! EQU 1 (
    echo [INFO] Skipping APK ^(up-to-date^)
    echo result=skipped> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 0
)

call "%ANDROID_DIR%\build_android.bat" %PROFILE%

set "ANDROID_ERR=!ERRORLEVEL!"

if !ANDROID_ERR! neq 0 (
    echo [ERROR] Android build failed
    echo result=failed> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 1
)

echo [INFO] Android:  %DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk

echo result=built> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
call :snap_update "apk_%PROFILE%" --exclude "%ANDROID_DIR%\zen_mobile\app\src\main\assets" "%ANDROID_DIR%\zen_mobile\frontend" "%DESKTOP_CORE_WEB%" "%ANDROID_DIR%\zen_mobile\app\src" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_android_api.aar" "..\src\auth" "..\src\common" "..\src\key" "..\src\lib.rs" "..\src\contact.rs" "..\src\interfaces\mod.rs" "..\src\interfaces\interface_wasm" "..\src\interfaces\interface_android" "..\src\indicators" "..\src\kline" "..\src\market" "..\src\movement" "..\src\pivot" "..\src\segment" "..\src\stroke" "..\Cargo.toml" "..\Cargo.lock" "%~dp0VERSION"

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

REM Gradle sync AAR copy in app/libs/ (regenerable, not committed)
if exist "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api.aar" del /f /q "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api.aar" 2>nul
if exist "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api-sources.jar" del /f /q "%ANDROID_DIR%\zen_mobile\app\libs\zen_android_api-sources.jar" 2>nul

call :cleanup_desktop_staging

call :cleanup_replay_staging

REM Clear incremental build status files and snapshot so clean+rebuild shows correct summary
del /f /q "%TEMP%\zen_app_status_*.txt" 2>nul
if exist "%TEMP%\zen_build_snap\zen_plugin_apps" rd /s /q "%TEMP%\zen_build_snap\zen_plugin_apps" 2>nul

echo [INFO] Application artifacts cleaned.

exit /b 0



:show_summary

if not "%QUIET%"=="1" (

    echo.

    echo ============================================================

    echo   BUILD SUMMARY ^(%MODE%, %PROFILE%^)

    echo ============================================================

    if /I "%MODE%"=="desktop" (

        call :check_and_print "Desktop" "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe" desktop

        goto :summary_done

    )

    if /I "%MODE%"=="replay" (

        call :check_and_print "Replay"  "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_replay\zen_replay.exe" replay

        goto :summary_done

    )

    if /I "%MODE%"=="apk" (

        if "%ZEN_ANDROID_STORE_FILE%"=="" (
            echo   Android:  [SKIPPED] Missing signing configuration
        ) else (
            call :check_and_print "Android" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk" apk
        )

        goto :summary_done

    )

    if /I "%MODE%"=="all" (

        call :check_and_print "Desktop" "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe" desktop

        call :check_and_print "Replay"  "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_replay\zen_replay.exe" replay

        if "%ZEN_ANDROID_STORE_FILE%"=="" (
            echo   Android:  [SKIPPED] Missing signing configuration
        ) else (
            call :check_and_print "Android" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk" apk
        )

        goto :summary_done

    )

)

:summary_done

exit /b 0

:check_and_print
REM Mirror root build.bat's check_and_print so the two summaries print identical
REM lines for the same artifact state ([FAILED] / [UP-TO-DATE] (path) / path).
set "LBL=%~1"
set "PTH=%~2"
set "STKEY=%~3"
if not exist "%PTH%" (
    echo   !LBL!: [FAILED]
    exit /b 0
)
if not "!STKEY!"=="" (
    set "APP_ST_FILE=%TEMP%\zen_app_status_!STKEY!_%PROFILE%.txt"
    if exist "!APP_ST_FILE!" (
        set "APP_ST_RESULT="
        for /f "usebackq tokens=1,* delims==" %%a in ("!APP_ST_FILE!") do (
            if "%%a"=="result" set "APP_ST_RESULT=%%b"
        )
        if "!APP_ST_RESULT!"=="skipped" (
            echo   !LBL!: [UP-TO-DATE] ^(!PTH!^)
            exit /b 0
        )
        if "!APP_ST_RESULT!"=="failed" (
            echo   !LBL!: [FAILED]
            exit /b 0
        )
    )
)
echo   !LBL!: !PTH!
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

