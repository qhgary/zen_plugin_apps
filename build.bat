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

REM ==================== Android Env Report ^(detect only, do not load^) ====================

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

REM Use PowerShell to merge: replace everything from the "## 禅中看缠..." heading
REM up to the screenshot section ("## 软件截图") with RELEASE.md. The screenshot
REM section is the primary end anchor (falling back to the next H2) so a README
REM that accumulated duplicate download blocks from an older sync always
REM collapses back to exactly one.
REM Paths are handed over through the environment, never the command line, so no
REM non-ASCII text is ever passed to Windows PowerShell 5.1. README.md is written
REM in place only when the merged text differs (mtime/git stay untouched
REM otherwise), with LF + no BOM ([IO.File]::WriteAllText) so the git-tracked
REM README.md keeps a stable encoding instead of gaining a BOM + CRLF.
REM The PowerShell step reports its outcome on stdout (NOHD / UNCHANGED / UPDATED
REM / WRITEFAIL) instead of an exit code, and stdout is captured to a temp file
REM and read back with set /p. Do NOT wrap this in for /f ('...'): cmd strips the
REM '^' escapes inside the single-quoted command and can fail to spawn it through
REM the child shell ("The system cannot find the file"), leaving the state empty.
REM Same temp-file + set /p workaround as :helper_pk_inject below.
set "ZEN_README_SYNC_R=!SYNC_README_FILE!"
set "ZEN_README_SYNC_REL=!SYNC_RELEASE_FILE!"
set "README_SYNC_STATE="
set "ZEN_README_SYNC_TMP=%TEMP%\zen_readme_sync_%RANDOM%.txt"
powershell -NoProfile -Command "$r=$env:ZEN_README_SYNC_R; $rel=$env:ZEN_README_SYNC_REL; $lines=@(Get-Content -LiteralPath $r -Encoding UTF8); $rl=@(Get-Content -LiteralPath $rel -Encoding UTF8); $p='^## '+[char]0x7985+[char]0x4E2D+[char]0x770B+[char]0x7F20; $h=-1; for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -cmatch $p){$h=$i;break}}; if($h -lt 0){'NOHD'; exit 0}; $e='^## '+[char]0x8F6F+[char]0x4EF6+[char]0x622A+[char]0x56FE; $n=-1; for($i=$h+1;$i -lt $lines.Count;$i++){if($lines[$i] -cmatch $e){$n=$i;break}}; if($n -lt 0){for($i=$h+1;$i -lt $lines.Count;$i++){if($lines[$i] -cmatch '^## '){$n=$i;break}}}; $f=@(); if($h -gt 0){$f=@($lines[0..($h-1)])}; $rem=@(); if($n -ge 0){$rem=@($lines[$n..($lines.Count-1)])}; $new=((@($f)+@($rl)+@('')+@($rem)) -join [char]10)+[char]10; [string]$old=Get-Content -LiteralPath $r -Raw -Encoding UTF8; $old=($old -replace '\r\n',([string][char]10)) -replace '\r',([string][char]10); if($old -eq $new){'UNCHANGED'; exit 0}; try{[System.IO.File]::WriteAllText($r,$new); 'UPDATED'}catch{'WRITEFAIL'}" > "!ZEN_README_SYNC_TMP!" 2>nul
set /p README_SYNC_STATE=<"!ZEN_README_SYNC_TMP!" 2>nul
del /f /q "!ZEN_README_SYNC_TMP!" >nul 2>&1
set "ZEN_README_SYNC_TMP="

if "!README_SYNC_STATE!"=="NOHD" (
    echo [WARN] README.md: download section heading not found, skipping RELEASE.md sync
    exit /b 0
)
if "!README_SYNC_STATE!"=="WRITEFAIL" (
    echo [ERROR] README.md: cannot write download section ^(README.md locked or read-only^)
    exit /b 1
)
if "!README_SYNC_STATE!"=="UPDATED" echo [INFO] README.md: download section updated from RELEASE.md
if "!README_SYNC_STATE!"=="" echo [WARN] README.md: RELEASE.md sync returned no result ^(PowerShell unavailable?^)
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

REM Duplicate-guard for the download section. An older sync implementation
REM inserted RELEASE.md before the heading on every run, so README.md
REM accumulated one extra copy of the whole download block per build. The
REM APK link line appears exactly once per download section and nowhere else
REM in README.md, so its count is the section count. Fail the build instead
REM of shipping a README whose download links repeat.
REM The path AND the marker go to PowerShell through the environment, like the
REM render steps below, so nothing non-ASCII ever reaches the command line.
set "ZEN_README_DUP=!README_SRC!"
set "ZEN_README_DUP_KEY=apk_aarch64-linux-android"
set "README_DUP_COUNT=?"
for /f "delims=" %%c in ('powershell -NoProfile -Command "@(Select-String -LiteralPath $env:ZEN_README_DUP -Encoding UTF8 -SimpleMatch $env:ZEN_README_DUP_KEY).Count"') do set "README_DUP_COUNT=%%c"
if not "!README_DUP_COUNT!"=="1" (
    echo [ERROR] README.md: download section duplicated - found !README_DUP_COUNT! copies, expected 1
    echo [ERROR] README.md: keep exactly one download section in README.md and RELEASE.md
    exit /b 1
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
call :render_readme || exit /b 1
call :check_go_tools || exit /b 1
call :build_desktop || exit /b 1
call :show_summary
exit /b 0



:mode_replay
call :render_readme || exit /b 1
call :check_go_tools || exit /b 1
call :build_replay || exit /b 1
call :show_summary
exit /b 0



:mode_apk
call :render_readme || exit /b 1
call :check_android_signing
if errorlevel 1 (
    echo [WARN] APK build skipped: Android signing environment not available.
    > "%TEMP%\zen_app_status_apk_%PROFILE%.txt" echo result=skipped
    call :show_summary
    exit /b 0
)
call :check_java_tools || exit /b 1
call :check_android_ndk || exit /b 1
call :build_apk || exit /b 1
call :show_summary
exit /b 0



:mode_all
call :render_readme || exit /b 1
call :check_go_tools || exit /b 1
call :build_desktop || exit /b 1
call :cleanup_desktop_staging
call :build_replay || exit /b 1
call :cleanup_replay_staging
call :check_android_signing
if errorlevel 1 (
    echo [WARN] APK build skipped: Android signing environment not available.
    > "%TEMP%\zen_app_status_apk_%PROFILE%.txt" echo result=skipped
)
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
REM Locate Android SDK first (mirror of :detect_ndk in build_android.bat).
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
REM Preserves zen_license.key and both watchlist names across clean.
REM All output is fully redirected (stdout+stderr) so a transient SMB/share
REM hiccup on network drives cannot leak stray error text into the log.
set "DIR=%~1"
set "TEMP_BACKUP=%TEMP%\zen_application_preserve_%RANDOM%"
mkdir "!TEMP_BACKUP!" >nul 2>&1
if exist "!DIR!\zen_license.key" copy /Y "!DIR!\zen_license.key" "!TEMP_BACKUP!\" >nul 2>&1
REM Legacy name is kept too: the rename to the dot name happens at app startup,
REM so cleaning before that would drop the user's watch list.
if exist "!DIR!\zen_watchlist.json" copy /Y "!DIR!\zen_watchlist.json" "!TEMP_BACKUP!\" >nul 2>&1
if exist "!DIR!\.zen_watchlist.json" copy /Y "!DIR!\.zen_watchlist.json" "!TEMP_BACKUP!\" >nul 2>&1
rd /s /q "!DIR!" >nul 2>&1
mkdir "!DIR!" >nul 2>&1
if exist "!TEMP_BACKUP!\zen_license.key" copy /Y "!TEMP_BACKUP!\zen_license.key" "!DIR!\" >nul 2>&1
if exist "!TEMP_BACKUP!\zen_watchlist.json" copy /Y "!TEMP_BACKUP!\zen_watchlist.json" "!DIR!\" >nul 2>&1
if exist "!TEMP_BACKUP!\.zen_watchlist.json" (
    copy /Y "!TEMP_BACKUP!\.zen_watchlist.json" "!DIR!\" >nul 2>&1
    REM copy resets file attributes, so re-apply the hidden flag after restore
    attrib +h "!DIR!\.zen_watchlist.json" >nul 2>&1
)
rd /s /q "!TEMP_BACKUP!" >nul 2>&1
exit /b 0

:restore_zen_debug_flag
REM Restore zen.html to the bytes this build replaced the debug flag in. The stash
REM is a per-build temp file rather than a .bak sidecar next to the source, so an
REM interrupted run can never restore an older generation over newer content.
if not defined ZEN_HTML_ORIG exit /b 0
REM Size, not existence: a stash left empty by a failed copy would otherwise
REM restore an empty zen.html over the real one.
for %%q in ("!ZEN_HTML_ORIG!") do (
    if not "%%~zQ"=="" if not "%%~zQ"=="0" copy /y "!ZEN_HTML_ORIG!" "%DESKTOP_APP_DIR%\zen.html" >nul 2>&1
    del /f /q "!ZEN_HTML_ORIG!" >nul 2>&1
)
set "ZEN_HTML_ORIG="
exit /b 0

:cleanup_desktop_staging
REM The zen.html debug flag is a build-time substitution -- undo it on every
REM cleanup path too, including the failure exits that stop before go build.
call :restore_zen_debug_flag

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
REM Collect excluded dirs as ';'-separated ABSOLUTE paths (RB_XDP).
REM IMPORTANT: must read %~2 BEFORE any shift. Earlier version shifted first
REM then read %~2 -- the intended EXCLUDE path was silently dropped and RB_XDP
REM captured the wrong argument (the next src path). Result: app\src\main\assets
REM wasn't excluded from the byte-content snapshot, syncZenAssets writes/cleanup
REM deletes would defeat the gate, and :need_rebuild always rebuilt APK.
set "RB_XDP=!RB_XDP!;%~2"
shift
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
    REM Same fix as :nr_handle_exclude: read %~2 before shifting.
    set "SU_XD=!SU_XD! /XD %~2"
    shift
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

:helper_pk_inject
REM Build-time parameter injection.
REM Usage: call :helper_pk_inject <rust target>
set "HPK_KEY="
if /I "%~1"=="%TARGET_X86_64%" set "HPK_KEY=PUBKEY_X86_64_PC_WINDOWS_MSVC"
if not defined HPK_KEY exit /b 0
set "HPK_LIST=%DIST_ROOT%\common\helper_pubkeys.env"
if not exist "!HPK_LIST!" (
    echo [WARN] helper_pubkeys.env not found, build-time value not injected ^(Go side stays empty = fail-fast^).
    exit /b 0
)
REM Same temp-file + set /p workaround as the SHA-256 blocks above.
set "HPK_TMP=%TEMP%\zen_helper_pk_read_%RANDOM%.txt"
powershell -NoProfile -Command ^
    "$key = $env:HPK_KEY; $list = $env:HPK_LIST; $pk = '';" ^
    "foreach ($l in Get-Content $list) { if ($l.StartsWith($key + '=')) { $pk = $l.Substring($key.Length + 1).Trim(); break } }" ^
    "if ($pk) { Set-Content -Path $env:HPK_TMP -Value $pk -Encoding ascii }"
set "HELPER_PK="
set /p HELPER_PK=<"!HPK_TMP!"
del /f /q "!HPK_TMP!" 2>nul
set "HPK_TMP="
if defined HELPER_PK (
    call :helper_pk_verify "%DIST_ROOT%\%~1\%PROFILE%\zen_auth_helper.exe" "!HELPER_PK!"
    if errorlevel 1 exit /b 1
    set "LDFLAGS=!LDFLAGS! -X main.helperSignPubKeyHex=!HELPER_PK!"
    echo   build-time value: injected
) else (
    echo [WARN] value not found in manifest, not injected ^(Go side stays empty = fail-fast^).
)
exit /b 0

REM Build-time consistency assertion.
REM Release only.
REM Usage: call :helper_pk_verify <helper exe path> <expected hex>
:helper_pk_verify
if /I not "%PROFILE%"=="release" exit /b 0
if not exist "%~1" exit /b 0
set "HPV_EXE=%~f1"
set "HPV_WANT=%~2"
set "HPV_RAW=%TEMP%\zen_hpk_verify_%RANDOM%.txt"
set "HPV_ERR=%TEMP%\zen_hpk_verify_err_%RANDOM%.txt"
"!HPV_EXE!" --print-attestation-pubkey > "!HPV_RAW!" 2> "!HPV_ERR!"
if !ERRORLEVEL! NEQ 0 (
    echo [ERROR] helper pubkey check failed: helper exited non-zero ^(!ERRORLEVEL!^)
    echo         !HPV_EXE!
    goto :helper_pk_verify_dump
)
set "HPV_LIVE="
for /f "usebackq tokens=1,* delims==" %%A in ("!HPV_RAW!") do (
    if /I "%%A"=="HELPER_ATTESTATION_PUBKEY_HEX" if not defined HPV_LIVE set "HPV_LIVE=%%B"
)
if not defined HPV_LIVE (
    echo [ERROR] helper pubkey check failed: no HELPER_ATTESTATION_PUBKEY_HEX in helper output
    echo         !HPV_EXE!
    goto :helper_pk_verify_dump
)
del /q "!HPV_RAW!" >nul 2>&1
del /q "!HPV_ERR!" >nul 2>&1
if "!HPV_WANT!"=="!HPV_LIVE!" (
    echo   helper pubkey check: OK
    exit /b 0
)
echo [ERROR] helper pubkey does not match the build-time value being injected:
echo [ERROR]   manifest ^(injected^) = !HPV_WANT!
echo [ERROR]   those bytes report   = !HPV_LIVE!
exit /b 1

:helper_pk_verify_dump
echo ---- helper stdout ----
if exist "!HPV_RAW!" type "!HPV_RAW!"
echo ---- helper stderr ----
if exist "!HPV_ERR!" type "!HPV_ERR!"
if exist "!HPV_RAW!" del /q "!HPV_RAW!" >nul 2>&1
if exist "!HPV_ERR!" del /q "!HPV_ERR!" >nul 2>&1
exit /b 1

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
    echo [ERROR] Pre-built license files missing in applications\dist\common. Restore dist\ from the release package ^(see SETUP.md^).
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
    exit /b 1
)
call :cleanup_desktop_staging

echo [INFO] Packing pre-built deps: helper ^(%TARGET_X86_64%^), wasm ^(%TARGET_WASM%^), html

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
REM Desktop/Replay embed Helper+WASM via go:embed; the gate compares the
REM embedded dist/ products (helper + wasm pkg) -- the only build inputs
REM this script can see, so a dependency change arrives as a product change.
REM docs\ and LICENSE.md are already checked by the HTML build step.
REM go:embed covers zen.html/JS/jscommon/pkg/lic/helper - all inputs checked.
call :need_rebuild "desktop_%PROFILE%" "!DESKTOP_OUT!" "%DESKTOP_APP_DIR%\zen.html" "%DESKTOP_APP_DIR%\ZenLocalService.js" "%DESKTOP_APP_DIR%\StockData.js" "%DESKTOP_APP_DIR%\zen_analysis_worker.js" "%DESKTOP_APP_DIR%\ZenStockSearch.js" "%DESKTOP_APP_DIR%\main.go" "%DESKTOP_APP_DIR%\helper_embed_darwin.go" "%DESKTOP_APP_DIR%\helper_embed_windows.go" "%DESKTOP_APP_DIR%\helper_proc_unix.go" "%DESKTOP_APP_DIR%\helper_proc_windows.go" "%DESKTOP_APP_DIR%\go.mod" "%DESKTOP_APP_DIR%\go.sum" "%DESKTOP_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "%DESKTOP_CORE_GO%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\common\%MANUAL_HTML%" "%~dp0VERSION"
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

REM Build-time parameter preparation.

set "BASE_FLAGS="
set "LDFLAGS=-s -w -X main._internalFlag=0 %BASE_FLAGS%"
if /I "%PROFILE%"=="debug" set "LDFLAGS=-X main._internalFlag=1 %BASE_FLAGS%"

REM Release mode: hide Windows console window
if /I "%PROFILE%"=="release" set "LDFLAGS=%LDFLAGS% -H windowsgui"

if /I "%PROFILE%"=="release" (
    REM Compute helper SHA-256 via PowerShell, written to a temp file, then
    REM read with set /p. set /p reads the first line of a file without
    REM forking a cmd parser, completely sidestepping cmd.exe for-loop
    REM tokenisation quirks (usebackq was unexpected at this time, etc.).
    set "HELPER_SHA_TMP=%TEMP%\zen_helper_sha_desktop.txt"
    powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 '%DESKTOP_APP_DIR%\%HELPER_NAME%').Hash.ToLower()" > "!HELPER_SHA_TMP!" 2>nul
    set "HELPER_SHA256="
    set /p HELPER_SHA256=<"!HELPER_SHA_TMP!"
    del /f /q "!HELPER_SHA_TMP!" 2>nul
    set "HELPER_SHA_TMP="
    if defined HELPER_SHA256 (
        set "LDFLAGS=!LDFLAGS! -X main.expectedHelperSHA256=!HELPER_SHA256!"
        echo   helper SHA-256: !HELPER_SHA256!
    ) else (
        echo [WARN] Failed to compute helper SHA-256, skipping runtime helper integrity check ^(not recommended^).
    )
)

REM Build-time parameter injection.
call :helper_pk_inject %DESKTOP_TARGET%
if errorlevel 1 (
    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
    exit /b 1
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

REM Replace the debug flag literal in zen.html (debug=true, release=false).
REM //go:embed requires this file inside the Go module dir, so the replace stays
REM in-place; the original bytes are stashed outside applications/ and restored
REM right after go build, so no build leaves a substituted source tree behind.
REM Idempotent: the pattern also matches an already-substituted "true"/"false"
REM literal, so a debug build followed by a release build (or vice versa) cannot
REM leave a stale debug flag behind. Hard-fail when the pattern is missing -- a
REM replace that silently no-ops ships release builds with debug logging enabled.
REM CRITICAL: Must use -Encoding UTF8 on Get-Content to preserve UTF-8
REM encoding. Without -Encoding UTF8, PowerShell 5.x defaults to ANSI/UTF-16,
REM which corrupts all multibyte (Chinese) characters.
set "ZEN_HTML_FLAG=false"
if /I "%PROFILE%"=="debug" set "ZEN_HTML_FLAG=true"
set "ZEN_HTML_ORIG="
if exist "zen.html" (
    REM Per-build stash kept outside the source tree: unlike a .bak sidecar next to
    REM zen.html it can never restore an older generation over newer content.
    set "ZEN_HTML_ORIG=%TEMP%\zen_html_orig_%RANDOM%.html"
    copy /y "zen.html" "!ZEN_HTML_ORIG!" >nul 2>&1
    if not exist "!ZEN_HTML_ORIG!" (
        echo [ERROR] zen.html debug flag backup failed
        cd /d "%~dp0"
        echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
        exit /b 1
    )

    REM Output goes to a temp file: a transient share hiccup on network drives
    REM can leak stray child-process noise here with exit 0; it only surfaces
    REM when the replace actually fails (exit 3).
    REM The payload must contain NO double quote cmd could pair up: build the
    REM quote character with [char]34, matching the README CSS-injection step
    REM above (backslash-quoted \" breaks pairing -> "was unexpected at this time").
    set "HTML_OUT_TMP=%TEMP%\zen_html_flag_%RANDOM%.txt"
    powershell -NoProfile -Command "$q=[char]34; $c = Get-Content -LiteralPath 'zen.html' -Raw -Encoding UTF8; $p = $q+'(__ZEN_DEBUG__|true|false)'+$q+' === '+$q+'true'+$q; $n = [regex]::Matches($c, $p).Count; $c = $c -replace $p, $q+'%ZEN_HTML_FLAG%'+$q+' === '+$q+'true'+$q; [System.IO.File]::WriteAllText('zen.html', $c, (New-Object System.Text.UTF8Encoding $false)); if ($n -lt 1) { [Console]::Error.WriteLine('zen.html debug flag pattern not found'); exit 3 }" > "!HTML_OUT_TMP!" 2>&1
    if errorlevel 1 (
        echo [ERROR] zen.html debug flag replace failed ^(exit !ERRORLEVEL!^)
        if exist "!HTML_OUT_TMP!" type "!HTML_OUT_TMP!"
        del /f /q "!HTML_OUT_TMP!" >nul 2>&1
        call :restore_zen_debug_flag
        cd /d "%~dp0"
        echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"
        exit /b 1
    )
    del /f /q "!HTML_OUT_TMP!" >nul 2>&1
    set "HTML_OUT_TMP="
)

REM Pin the emitted architecture. "go build" with no GOARCH produces a binary
REM for the build host, so on an ARM64 machine it would put an ARM64 exe into a
REM folder labelled x86_64-pc-windows-msvc. This Go code has no cgo, so the
REM cross compile needs no C toolchain. Cleared right after: the same cmd
REM session later runs go install, gomobile and gradle.
set "GOOS=windows"
set "GOARCH=amd64"
set "CGO_ENABLED=0"
REM go build output is captured to a temp file, not streamed to the console:
REM on network drives (Parallels/VMware/SMB shares) the go subprocess tree can
REM emit stray "The system cannot find the file specified." noise while still
REM exiting 0 and producing a valid exe. Capturing keeps that noise out of the
REM log; on failure the full output is replayed below.
set "GO_OUT_TMP=%TEMP%\zen_go_build_desktop_%RANDOM%.txt"
go build -buildvcs=false %GO_TRIMPATH% -ldflags "%LDFLAGS%" -o "..\..\dist\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe" . > "!GO_OUT_TMP!" 2>&1

set "GO_ERR=!ERRORLEVEL!"

set "GOOS="
set "GOARCH="
set "CGO_ENABLED="

cd /d "%~dp0"

if !GO_ERR! neq 0 (

    echo [ERROR] Go desktop build failed

    if exist "!GO_OUT_TMP!" type "!GO_OUT_TMP!"

    call :cleanup_desktop_staging

    echo result=failed> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"

    del /f /q "!GO_OUT_TMP!" >nul 2>&1

    exit /b 1

)

REM Exit 0 with non-empty output (transient share noise): surfaced as a WARN
REM so the log stays honest without failing a good build.
for %%A in ("!GO_OUT_TMP!") do set "GO_OUT_SIZE=%%~zA"
if defined GO_OUT_SIZE if !GO_OUT_SIZE! GTR 0 (
    echo [WARN] go build exited 0 with output:
    type "!GO_OUT_TMP!"
)
del /f /q "!GO_OUT_TMP!" >nul 2>&1
set "GO_OUT_TMP="
set "GO_OUT_SIZE="

echo [INFO] Desktop:  %DIST_ROOT%\%DESKTOP_TARGET%\%PROFILE%\zen_desktop\zen_desktop.exe

echo result=built> "%TEMP%\zen_app_status_desktop_%PROFILE%.txt"

REM Restore zen.html before anything reads the source again (snapshots included).
call :restore_zen_debug_flag

REM Update snapshot so next build can detect up-to-date
call :snap_update "desktop_%PROFILE%" "%DESKTOP_APP_DIR%\zen.html" "%DESKTOP_APP_DIR%\ZenLocalService.js" "%DESKTOP_APP_DIR%\StockData.js" "%DESKTOP_APP_DIR%\zen_analysis_worker.js" "%DESKTOP_APP_DIR%\ZenStockSearch.js" "%DESKTOP_APP_DIR%\main.go" "%DESKTOP_APP_DIR%\helper_embed_darwin.go" "%DESKTOP_APP_DIR%\helper_embed_windows.go" "%DESKTOP_APP_DIR%\helper_proc_unix.go" "%DESKTOP_APP_DIR%\helper_proc_windows.go" "%DESKTOP_APP_DIR%\go.mod" "%DESKTOP_APP_DIR%\go.sum" "%DESKTOP_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "%DESKTOP_CORE_GO%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\common\%MANUAL_HTML%" "%~dp0VERSION"

exit /b 0



REM ==================== Replay HTML JS Obfuscation ====================
REM Obfuscate inline JavaScript in replay.html for release builds.
REM Uses javascript-obfuscator (same tool as WASM JS glue code obfuscation).
REM Backup is created before obfuscation and restored after Go build.

:obfuscate_replay_html

set "REPLAY_HTML=%REPLAY_APP_DIR%\replay.html"

REM Profile gate comes first: debug builds never obfuscate, so they must not
REM probe for the toolchain nor complain about the missing file either.
if /I not "%PROFILE%"=="release" exit /b 0

if not exist "%REPLAY_HTML%" (
    echo [ERROR] replay.html not found for obfuscation
    exit /b 1
)

REM Tool availability is probed here, at the point of use, and only here: node
REM and javascript-obfuscator cannot stop replay.html from being embedded, so a
REM missing one warns and continues (same tier as the closed-side obfuscation
REM and leak-strip steps, same wording as applications\build.sh). Without this
REM probe a machine that has the module under %APPDATA%\npm but no node on PATH
REM fell into the "ran and failed" branch instead.
where node >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN] replay.html JS obfuscation SKIPPED: node not found, run 'npm install -g javascript-obfuscator'
    exit /b 0
)

REM Find javascript-obfuscator module.
REM Order (fast paths first, npm-fork last):
REM   1. %APPDATA%\npm\node_modules\javascript-obfuscator  (default npm global prefix on Windows)
REM   2. %ProgramFiles%\nodejs\node_modules\javascript-obfuscator  (MSI installer location)
REM   3. derive from `where node` location  (covers custom node installs)
REM   4. `npm root -g` fallback  (slow on some setups; see comment below)
REM Why not just `npm root -g`? It forks node + npm and can hang indefinitely
REM when run from a network-share cwd if there is a stale lock or the npm
REM cache is in a degraded state. The hard-coded paths above cover >99% of
REM installs and finish in <50ms instead of seconds-to-never.
set "OBF_MODULE="
for %%p in (
    "%APPDATA%\npm\node_modules\javascript-obfuscator"
    "%ProgramFiles%\nodejs\node_modules\javascript-obfuscator"
) do (
    if exist "%%~p" set "OBF_MODULE=%%~p"
)
if not defined OBF_MODULE (
    REM Derive from `where node` output (first line = node.exe full path).
    for /f "delims=" %%n in ('where node 2^>nul') do (
        if not defined _node_full set "_node_full=%%n"
    )
    if defined _node_full (
        REM node lives in <prefix>\node.exe; siblings should contain node_modules\javascript-obfuscator.
        for %%d in ("!_node_full!") do set "_node_dir=%%~dpn"
        if exist "!_node_dir!\node_modules\javascript-obfuscator" set "OBF_MODULE=!_node_dir!\node_modules\javascript-obfuscator"
    )
)
if not defined OBF_MODULE (
    REM Last-resort: ask npm directly. This fork is the source of the
    REM occasional hang after `build.bat clean`; we keep it for completeness
    REM but the fast paths above should usually win.
    REM Use the resolved %TEMP% path directly (not via a variable) to avoid
    REM cmd's `>` redirection quirk that occasionally writes the literal
    REM redirection token to cwd instead of expanding it.
    set "NPM_ROOT_LINE="
    if defined TEMP (
        > nul 2>&1 (call npm root -g > "%TEMP%\zen_npm_root.txt")
        if exist "%TEMP%\zen_npm_root.txt" (
            set /p NPM_ROOT_LINE=<"%TEMP%\zen_npm_root.txt"
            del /f /q "%TEMP%\zen_npm_root.txt" 2>nul
        )
    )
    if not "!NPM_ROOT_LINE!"=="" (
        if exist "!NPM_ROOT_LINE!\javascript-obfuscator" set "OBF_MODULE=!NPM_ROOT_LINE!\javascript-obfuscator"
    )
)

if not defined OBF_MODULE (
    echo [WARN] replay.html JS obfuscation SKIPPED: javascript-obfuscator not found, run 'npm install -g javascript-obfuscator'
    exit /b 0
)

REM Backup original
copy /Y "%REPLAY_HTML%" "%REPLAY_HTML%.bak" >nul

REM Create temporary obfuscation script
set "OBF_SCRIPT=%TEMP%\zen_replay_obf_%RANDOM%.js"

REM Disable delayed expansion so '!' in JS (!==, !jsContent) is output literally.
REM Inside the parens block we must escape: paren ^) ^< ^> and regex ^ as ^^
REM Obfuscation seed: always random per build. The source change itself does
REM not need to be the seed -- a fresh !RANDOM! per run gives every release
REM artifact different obfuscation bytes.
set "SEED="
set /a "SEED=!RANDOM! * 32768 + !RANDOM!"
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
) > "%OBF_SCRIPT%"
endlocal

REM Log shape mirrors the closed-side obfuscation: the node script stays quiet,
REM this step prints one OK line, and its output is kept only to be dumped on failure.
set "OBF_LOG=%TEMP%\zen_replay_obf_%RANDOM%.log"
node "%OBF_SCRIPT%" "%REPLAY_HTML%" "%OBF_MODULE%" "%SEED%" > "%OBF_LOG%" 2>&1
set "OBF_ERR=!ERRORLEVEL!"
del /f /q "%OBF_SCRIPT%" 2>nul

if !OBF_ERR! neq 0 (
    echo [WARN] replay.html JS obfuscation failed ^(rc=!OBF_ERR!^), restoring original
    type "%OBF_LOG%"
    del /f /q "%OBF_LOG%" 2>nul
    copy /Y "%REPLAY_HTML%.bak" "%REPLAY_HTML%" >nul
    exit /b 0
)

del /f /q "%OBF_LOG%" 2>nul
echo [INFO] replay.html JS obfuscation: OK
exit /b 0


:restore_replay_html

set "REPLAY_HTML=%REPLAY_APP_DIR%\replay.html"

if exist "%REPLAY_HTML%.bak" (
    copy /Y "%REPLAY_HTML%.bak" "%REPLAY_HTML%" >nul
    del /f /q "%REPLAY_HTML%.bak" 2>nul
)

exit /b 0

:restore_replay_debug_flag
REM Same stash-and-restore for replay.html's debug flag. It has to run AFTER
REM :restore_replay_html: the obfuscation backup is taken once the flag is already
REM substituted, so restoring from it alone would leave substituted bytes behind.
if not defined REPLAY_HTML_ORIG exit /b 0
REM Size, not existence: a stash left empty by a failed copy would otherwise
REM restore an empty replay.html over the real one.
for %%q in ("!REPLAY_HTML_ORIG!") do (
    if not "%%~zQ"=="" if not "%%~zQ"=="0" copy /y "!REPLAY_HTML_ORIG!" "%REPLAY_APP_DIR%\replay.html" >nul 2>&1
    del /f /q "!REPLAY_HTML_ORIG!" >nul 2>&1
)
set "REPLAY_HTML_ORIG="
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

REM The replay.html debug flag is a build-time substitution too -- undo it on
REM every cleanup path, including the failure exits that stop before go build.
call :restore_replay_debug_flag

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
REM Desktop/Replay embed Helper+WASM via go:embed; the gate compares the
REM embedded dist/ products (helper + wasm pkg) -- the only build inputs
REM this script can see, so a dependency change arrives as a product change.
REM docs\ and LICENSE.md are already checked by the HTML build step.
call :need_rebuild "replay_%PROFILE%" "!REPLAY_OUT!" "%REPLAY_APP_DIR%\replay.html" "%REPLAY_APP_DIR%\main.go" "%REPLAY_APP_DIR%\helper_embed_darwin.go" "%REPLAY_APP_DIR%\helper_embed_windows.go" "%REPLAY_APP_DIR%\helper_proc_unix.go" "%REPLAY_APP_DIR%\helper_proc_windows.go" "%REPLAY_APP_DIR%\go.mod" "%REPLAY_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%~dp0VERSION"
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
    REM Same workaround as build_desktop above: PowerShell output to temp
    REM file, then set /p reads the first line. Avoids the for /f + usebackq
    REM path that was failing in some build contexts.
    set "HELPER_SHA_TMP=%TEMP%\zen_helper_sha_replay.txt"
    powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 '%REPLAY_APP_DIR%\%HELPER_NAME%').Hash.ToLower()" > "!HELPER_SHA_TMP!" 2>nul
    set "HELPER_SHA256="
    set /p HELPER_SHA256=<"!HELPER_SHA_TMP!"
    del /f /q "!HELPER_SHA_TMP!" 2>nul
    set "HELPER_SHA_TMP="
    if defined HELPER_SHA256 (
        set "LDFLAGS=!LDFLAGS! -X main.expectedHelperSHA256=!HELPER_SHA256!"
        echo   helper SHA-256: !HELPER_SHA256!
    ) else (
        echo [WARN] Failed to compute helper SHA-256, skipping integrity check.
    )
)

REM Build-time parameter injection.
call :helper_pk_inject %REPLAY_TARGET%
if errorlevel 1 (
    echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"
    exit /b 1
)

REM Replace the debug flag literal in replay.html (debug=true, release=false).
REM //go:embed requires this file inside the Go module dir, so the replace stays
REM in-place; the original bytes are stashed outside applications/ and restored
REM right after go build, so no build leaves a substituted source tree behind.
REM Idempotent: the pattern also matches an already-substituted "true"/"false"
REM literal, so a debug build followed by a release build (or vice versa) cannot
REM leave a stale debug flag behind. Hard-fail when the pattern is missing -- a
REM replace that silently no-ops ships release builds with debug logging enabled.
REM This runs BEFORE :obfuscate_replay_html on purpose: the obfuscator moves the
REM "__ZEN_DEBUG__" literal into its string array, so the pattern only matches
REM while the file is still un-obfuscated.
REM Same shape as the zen.html step in :build_desktop, including -Encoding UTF8
REM (without it PS 5.x defaults to ANSI/UTF-16 and corrupts every multibyte
REM character). The path travels in %REPLAY_HTML_PATH% because cmd is still in
REM applications/ here; the app dir is only the cwd later, right before go build.
set "REPLAY_HTML_FLAG=false"
if /I "%PROFILE%"=="debug" set "REPLAY_HTML_FLAG=true"
set "REPLAY_HTML_ORIG="
if exist "%REPLAY_APP_DIR%\replay.html" (
    REM Per-build stash kept outside the source tree: unlike a .bak sidecar next to
    REM replay.html it can never restore an older generation over newer content.
    set "REPLAY_HTML_ORIG=%TEMP%\replay_html_orig_%RANDOM%.html"
    copy /y "%REPLAY_APP_DIR%\replay.html" "!REPLAY_HTML_ORIG!" >nul 2>&1
    if not exist "!REPLAY_HTML_ORIG!" (
        echo [ERROR] replay.html debug flag backup failed
        call :cleanup_replay_staging
        echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"
        exit /b 1
    )

    REM Output goes to a temp file: a transient share hiccup on network drives
    REM can leak stray child-process noise here with exit 0; it only surfaces
    REM when the replace actually fails (exit 3).
    REM Same quote discipline as the zen.html step: NO double quote in the
    REM payload, build it with [char]34 (backslash-quoted \" breaks cmd pairing).
    set "REPLAY_HTML_PATH=%REPLAY_APP_DIR%\replay.html"
    set "REPLAY_HTML_OUT_TMP=%TEMP%\replay_html_flag_%RANDOM%.txt"
    powershell -NoProfile -Command "$q=[char]34; $c = Get-Content -LiteralPath $env:REPLAY_HTML_PATH -Raw -Encoding UTF8; $p = $q+'(__ZEN_DEBUG__|true|false)'+$q+' === '+$q+'true'+$q; $n = [regex]::Matches($c, $p).Count; $c = $c -replace $p, $q+'%REPLAY_HTML_FLAG%'+$q+' === '+$q+'true'+$q; [System.IO.File]::WriteAllText($env:REPLAY_HTML_PATH, $c, (New-Object System.Text.UTF8Encoding $false)); if ($n -lt 1) { [Console]::Error.WriteLine('replay.html debug flag pattern not found'); exit 3 }" > "!REPLAY_HTML_OUT_TMP!" 2>&1
    if errorlevel 1 (
        echo [ERROR] replay.html debug flag replace failed ^(exit !ERRORLEVEL!^)
        if exist "!REPLAY_HTML_OUT_TMP!" type "!REPLAY_HTML_OUT_TMP!"
        del /f /q "!REPLAY_HTML_OUT_TMP!" >nul 2>&1
        call :restore_replay_debug_flag
        call :cleanup_replay_staging
        echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"
        exit /b 1
    )
    del /f /q "!REPLAY_HTML_OUT_TMP!" >nul 2>&1
    set "REPLAY_HTML_OUT_TMP="
    set "REPLAY_HTML_PATH="
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

REM Same architecture pin as the desktop build, see :build_desktop.
set "GOOS=windows"
set "GOARCH=amd64"
set "CGO_ENABLED=0"
REM Same go build output capture as :build_desktop (network-drive noise with
REM exit 0 stays out of the log; failures replay the full output).
set "GO_OUT_TMP=%TEMP%\zen_go_build_replay_%RANDOM%.txt"
go build -buildvcs=false %GO_TRIMPATH% -ldflags "%LDFLAGS%" -o "..\..\dist\%REPLAY_TARGET%\%PROFILE%\zen_replay\zen_replay.exe" . > "!GO_OUT_TMP!" 2>&1

set "GO_ERR=!ERRORLEVEL!"

set "GOOS="
set "GOARCH="
set "CGO_ENABLED="

cd /d "%~dp0"

REM Restore original replay.html (obfuscated version was embedded in Go binary)
call :restore_replay_html

REM Restore the debug flag bytes before anything reads the source again
REM (snapshots included). This must come after :restore_replay_html, whose
REM backup still carries the substituted flag.
call :restore_replay_debug_flag

if !GO_ERR! neq 0 (

    echo [ERROR] Go replay build failed

    if exist "!GO_OUT_TMP!" type "!GO_OUT_TMP!"

    call :cleanup_replay_staging

    echo result=failed> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"

    del /f /q "!GO_OUT_TMP!" >nul 2>&1

    exit /b 1

)

for %%A in ("!GO_OUT_TMP!") do set "GO_OUT_SIZE=%%~zA"
if defined GO_OUT_SIZE if !GO_OUT_SIZE! GTR 0 (
    echo [WARN] go build exited 0 with output:
    type "!GO_OUT_TMP!"
)
del /f /q "!GO_OUT_TMP!" >nul 2>&1
set "GO_OUT_TMP="
set "GO_OUT_SIZE="

echo [INFO] Replay:   %DIST_ROOT%\%REPLAY_TARGET%\%PROFILE%\zen_replay\zen_replay.exe

echo result=built> "%TEMP%\zen_app_status_replay_%PROFILE%.txt"

REM Update snapshot so next build can detect up-to-date
call :snap_update "replay_%PROFILE%" "%REPLAY_APP_DIR%\replay.html" "%REPLAY_APP_DIR%\main.go" "%REPLAY_APP_DIR%\helper_embed_darwin.go" "%REPLAY_APP_DIR%\helper_embed_windows.go" "%REPLAY_APP_DIR%\helper_proc_unix.go" "%REPLAY_APP_DIR%\helper_proc_windows.go" "%REPLAY_APP_DIR%\go.mod" "%REPLAY_APP_DIR%\zen_version.js" "%DESKTOP_CORE_WEB%" "!HELPER_SRC!" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%~dp0VERSION"

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
    echo [ERROR] Pre-built license files missing in applications\dist\common. Restore dist\ from the release package ^(see SETUP.md^).
    echo result=failed> "%TEMP%\zen_app_status_apk_%PROFILE%.txt"
    exit /b 1
)

REM Incremental build: skip if nothing changed since last build.
REM Inputs: the dist/ products this script consumes (wasm pkg + AAR) plus the
REM gradle scripts. The scripts belong there because they change the packaged
REM APK (asset sync, signing, output naming) without touching anything under
REM app\src -- a source-only gate is blind to them.
REM docs\ and LICENSE.md are already checked by the HTML build step.
REM Exclude app\src\main\assets: syncZenAssets writes there during the build
REM and cleanupZenSyncedAssets deletes files afterward, which would otherwise
REM always make app\src appear newer than the APK, defeating incremental builds.
set "APK_OUT=%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk"
call :need_rebuild "apk_%PROFILE%" --exclude "%ANDROID_DIR%\zen_mobile\app\src\main\assets" "!APK_OUT!" "%ANDROID_DIR%\zen_mobile\frontend" "%DESKTOP_CORE_WEB%" "%ANDROID_DIR%\zen_mobile\app\src" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_android_api.aar" "%~dp0VERSION"
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
call :snap_update "apk_%PROFILE%" --exclude "%ANDROID_DIR%\zen_mobile\app\src\main\assets" "%ANDROID_DIR%\zen_mobile\frontend" "%DESKTOP_CORE_WEB%" "%ANDROID_DIR%\zen_mobile\app\src" "%DIST_ROOT%\%TARGET_WASM%\%PROFILE%\pkg" "%DIST_ROOT%\common\%LIC_HTML%" "%DIST_ROOT%\common\%LIC_JS%" "%DIST_ROOT%\common\%ZEN_ERR_JS%" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_android_api.aar" "%~dp0VERSION"

exit /b 0



:do_clean

echo.

echo ============================================================

echo   Cleaning Application Artifacts

echo ============================================================

REM Clean all generated artifacts, preserving pre-built binaries
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

        set "APK_ST_FILE=%TEMP%\zen_app_status_apk_%PROFILE%.txt"
        set "APK_ST_RESULT="
        if exist "!APK_ST_FILE!" (
            for /f "usebackq tokens=1,* delims==" %%a in ("!APK_ST_FILE!") do (
                if "%%a"=="result" set "APK_ST_RESULT=%%b"
            )
        )
        if "!APK_ST_RESULT!"=="skipped" (
            echo   Android:  [SKIPPED] Missing signing configuration
        ) else (
            call :check_and_print "Android" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk" apk
        )

        goto :summary_done

    )

    if /I "%MODE%"=="all" (

        call :check_and_print "Desktop" "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_desktop\zen_desktop.exe" desktop

        call :check_and_print "Replay"  "%DIST_ROOT%\%TARGET_X86_64%\%PROFILE%\zen_replay\zen_replay.exe" replay

        set "APK_ST_FILE=%TEMP%\zen_app_status_apk_%PROFILE%.txt"
        set "APK_ST_RESULT="
        if exist "!APK_ST_FILE!" (
            for /f "usebackq tokens=1,* delims==" %%a in ("!APK_ST_FILE!") do (
                if "%%a"=="result" set "APK_ST_RESULT=%%b"
            )
        )
        if "!APK_ST_RESULT!"=="skipped" (
            echo   Android:  [SKIPPED] Missing signing configuration
        ) else (
            call :check_and_print "Android" "%DIST_ROOT%\aarch64-linux-android\%PROFILE%\zen_mobile\zen_mobile_universal.apk" apk
        )

        goto :summary_done

    )

)

:summary_done
echo ============================================================
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

