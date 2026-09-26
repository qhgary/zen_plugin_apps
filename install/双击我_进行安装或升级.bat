@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
goto :main

REM ============================================================
REM  Zen Plugin - TDX DLL Installer/Upgrader
REM  OS: Windows 7 ~ Windows 11, 32-bit/64-bit
REM  Encoding: GBK (chcp 936). Do NOT re-encode to UTF-8.
REM  Usage: DOUBLE-CLICK to run. Script auto-elevates via PowerShell (UAC).
REM         Works from local disks and mapped/UNC network drives (network
REM         paths are staged to %PUBLIC%\zen_install_tmp before elevation).

:main
set "LOG_FILE=%TEMP%\zen_install.log"
echo ============================================================ >> "!LOG_FILE!" 2>nul
echo Zen Plugin Install Log - %DATE% %TIME% >> "!LOG_FILE!" 2>nul
echo ============================================================ >> "!LOG_FILE!" 2>nul
echo [LOG] Script started >> "!LOG_FILE!" 2>nul
echo [LOG] OS: %OS% / %PROCESSOR_ARCHITECTURE% >> "!LOG_FILE!" 2>nul
ver >> "!LOG_FILE!" 2>nul
echo [LOG] Arg1=%~1 CWD=%CD% >> "!LOG_FILE!" 2>nul
echo [LOG] %~f0 >> "!LOG_FILE!" 2>nul

REM --- PowerShell availability check (auto-install depends on PS) ---
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto :ps_missing
powershell -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 goto :ps_missing
echo [LOG] PS check ok >> "!LOG_FILE!" 2>nul
goto :ps_done
:ps_missing
echo [LOG] PS check FAILED - auto install requires PowerShell >> "!LOG_FILE!" 2>nul
echo [LOG] Expected at: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe >> "!LOG_FILE!" 2>nul
echo.
    echo [错误] 未检测到 Windows PowerShell 模块, 自动安装无法继续
echo.
    echo PowerShell 是 Windows 系统自带的, 当前系统可能已将其精简或移除
    echo 请按用户手册 通达信插件安装 一章 下的 "备选:手动安装" 完成安装:
    echo   1. 将 tdx_zen.dll dlls.ini tdx_zen.tn6 复制到通达信目录 T0002\dlls\
    echo   2. 将 tdx_zen.dll 复制到通达信目录 plugin\ 目录
echo.
pause
exit /b 1
:ps_done

REM ============================================================
REM Self-elevation bootstrap (double-click friendly)
REM ============================================================
if /i "%~1"=="ZEN_ELEVATED" goto :elevated_ok
net session >nul 2>&1
if !ERRORLEVEL! EQU 0 goto :elevated_ok
echo [LOG] Not elevated, preparing elevation >> "!LOG_FILE!" 2>nul
REM Always stage the payload to a local public dir before elevating:
REM the elevated process may not see network/virtual drives (Z: etc),
REM so the new instance must run from a guaranteed-local path.
set "STAGE_DIR=%PUBLIC%\zen_install_tmp"
echo [LOG] Staging install files to !STAGE_DIR! >> "!LOG_FILE!" 2>nul
if exist "!STAGE_DIR!" rd /s /q "!STAGE_DIR!" 2>nul
mkdir "!STAGE_DIR!" 2>nul
if errorlevel 1 echo [LOG] ERROR: mkdir staging dir failed >> "!LOG_FILE!" 2>nul
copy /y "%~f0" "!STAGE_DIR!\" >nul 2>&1
if errorlevel 1 echo [LOG] ERROR: copy script to staging failed >> "!LOG_FILE!" 2>nul
for %%F in (tdx_zen.dll dlls.ini tdx_zen.tn6 zen_license.key) do (
    if exist "%~dp0%%F" (
        copy /y "%~dp0%%F" "!STAGE_DIR!\" >nul 2>&1
        if errorlevel 1 echo [LOG] ERROR: staging copy failed: %%F >> "!LOG_FILE!" 2>nul
    )
)
if not exist "!STAGE_DIR!\%~nx0" goto :elevate_fail
set "ELEV_TARGET=!STAGE_DIR!\%~nx0"
echo [LOG] Requesting elevation: !ELEV_TARGET! >> "!LOG_FILE!" 2>nul
echo.
echo   正在请求管理员权限, 即将弹出权限窗口请点 [是]...
echo.
powershell -NoProfile -Command "Start-Process -FilePath '!ELEV_TARGET!' -ArgumentList 'ZEN_ELEVATED' -Verb RunAs" >nul 2>&1
if errorlevel 1 (
    echo [LOG] ERROR: elevation request failed or was cancelled by user >> "!LOG_FILE!" 2>nul
    powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('自动提权失败。可能原因:UAC 已禁用, 或系统缺少 PowerShell。本脚本会自动提权, 无需手动右键。', '禅中看缠 - 安装')" >nul 2>&1
    if errorlevel 1 (
        echo   [提示] 自动提权失败 ^(UAC 已禁用, 或系统缺少 PowerShell^)
        echo   解决方法: 在系统设置中启用 UAC, 然后再次双击本脚本
        echo   ^(网络盘会自动中转暂存到 %PUBLIC%, 无需手动操作^)
        ping -n 11 127.0.0.1 >nul
    )
)
exit /b

:elevate_fail
echo [LOG] ERROR: staging elevation target missing - staging incomplete >> "!LOG_FILE!" 2>nul
echo [LOG] Target expected: !STAGE_DIR!\%~nx0 >> "!LOG_FILE!" 2>nul
powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('无法创建临时安装目录, 安装终止。请将整个安装目录拷贝到本地硬盘后再运行。', '禅中看缠 - 安装')" >nul 2>&1
if errorlevel 1 (
    echo.
    echo [错误] 无法创建临时安装目录, 安装终止
    echo 请将整个安装目录拷贝到本地硬盘后再运行本脚本
    ping -n 11 127.0.0.1 >nul
)
exit /b 1

:elevated_ok
echo [LOG] Elevation confirmed >> "!LOG_FILE!" 2>nul
echo [LOG] Script dir: %~dp0 >> "!LOG_FILE!" 2>nul

pushd "%~dp0" 2>nul

REM --- File name constants ---
set "DLL_NAME=tdx_zen.dll"
set "INI_NAME=dlls.ini"
set "TN6_NAME=tdx_zen.tn6"
set "LIC_NAME=zen_license.key"
set "TDX_EXE=tdxw.exe"
set "TDX_DLLS_SUBDIR=T0002\dlls"
set "TDX_PLUGIN_SUBDIR=plugin"

set "SCRIPT_DIR=%~dp0"
if "!SCRIPT_DIR:~-1!"=="\" set "SCRIPT_DIR=!SCRIPT_DIR:~0,-1!"
echo [LOG] SCRIPT_DIR = !SCRIPT_DIR! >> "!LOG_FILE!" 2>nul

REM -- Admin session cannot see mapped drives; resolve UNC via registry --
set "_ANY=0"
if exist "!SCRIPT_DIR!\%DLL_NAME%" set "_ANY=1"
if exist "!SCRIPT_DIR!\%INI_NAME%" set "_ANY=1"
if exist "!SCRIPT_DIR!\%TN6_NAME%" set "_ANY=1"
if exist "!SCRIPT_DIR!\%LIC_NAME%" set "_ANY=1"
if "!_ANY!"=="0" (
    echo [LOG] Script dir not accessible, trying UNC >> "!LOG_FILE!" 2>nul
    for %%A in ("!SCRIPT_DIR!\") do set "_DRV=%%~dA"
    set "_DRV=!_DRV:~0,1!"
    echo [LOG] Drive: !_DRV! >> "!LOG_FILE!" 2>nul
    for /f "tokens=2*" %%a in ('reg query "HKCU\Network\!_DRV!" 2^>nul ^| findstr /i "RemotePath"') do (
        set "_UNC=%%b"
        echo [LOG] UNC = !_UNC! >> "!LOG_FILE!" 2>nul
        set "SCRIPT_DIR=!_UNC!!SCRIPT_DIR:~2!"
        echo [LOG] SCRIPT_DIR = !SCRIPT_DIR! >> "!LOG_FILE!" 2>nul
    )
    if exist "!SCRIPT_DIR!\%DLL_NAME%" set "_ANY=1"
    if exist "!SCRIPT_DIR!\%INI_NAME%" set "_ANY=1"
    if exist "!SCRIPT_DIR!\%TN6_NAME%" set "_ANY=1"
    if exist "!SCRIPT_DIR!\%LIC_NAME%" set "_ANY=1"
)

if "!_ANY!"=="0" (
    echo. >> "!LOG_FILE!" 2>nul
    echo [ERROR] No install files found >> "!LOG_FILE!" 2>nul
    echo Path: %~dp0 >> "!LOG_FILE!" 2>nul
    echo.
    echo [错误] 未找到任何安装文件
    echo 脚本目录: %~dp0
    echo.
    echo 请将所有安装文件与本脚本放在同一目录再运行
    echo 详细日志已记录到: !LOG_FILE!
    pause
    exit /b 1
)

echo [LOG] Install files accessible, continuing >> "!LOG_FILE!" 2>nul
echo [LOG] Files: DLL=!HAS_DLL! INI=!HAS_INI! TN6=!HAS_TN6! LIC=!HAS_LIC! ARCH=!DLL_ARCH! >> "!LOG_FILE!" 2>nul

set "DLL_FILE=!SCRIPT_DIR!\!DLL_NAME!"
set "INI_FILE=!SCRIPT_DIR!\!INI_NAME!"
set "TN6_FILE=!SCRIPT_DIR!\!TN6_NAME!"
set "LIC_FILE=!SCRIPT_DIR!\!LIC_NAME!"
set "DLL_ARCH=unknown"
set "TDX_DIR="
set "VERIFY_FAIL=0"
set "VERIFY_TOTAL=0"
set "PADSP=                                                                                                                                                                "
call :get_width

echo.
echo ============================================================
echo   禅中看缠 - 通达信 DLL 插件安装/升级
echo ============================================================

REM === 步骤1: 检查安装文件 ===
echo [步骤1] 检查安装文件
echo.

set "HAS_DLL=0"
set "HAS_INI=0"
set "HAS_TN6=0"
set "HAS_LIC=0"

if exist "!DLL_FILE!" (
    set "HAS_DLL=1"
    call :detect_dll_arch "!DLL_FILE!" DLL_ARCH
    if "!DLL_ARCH!"=="32" (
        echo   %DLL_NAME% ...... [找到] [32 位]
    ) else if "!DLL_ARCH!"=="64" (
        echo   %DLL_NAME% ...... [找到] [64 位]
    ) else (
        echo   %DLL_NAME% ...... [找到]
    )
) else (
    echo   %DLL_NAME% ...... [缺失]
)

if exist "!INI_FILE!" (
    set "HAS_INI=1"
    echo   %INI_NAME% ......... [找到]
) else (
    echo   %INI_NAME% ......... [缺失]
)

if exist "!TN6_FILE!" (
    set "HAS_TN6=1"
    echo   %TN6_NAME% ...... [找到]
) else (
    echo   %TN6_NAME% ...... [缺失]
)

if exist "!LIC_FILE!" (
    set "HAS_LIC=1"
    echo   %LIC_NAME% .. [授权文件]
) else (
    echo   %LIC_NAME% .. [无 - 试用模式]
)

REM === Step 1b: Determine target TDX architecture ===
if "!HAS_DLL!"=="1" (
    if "!DLL_ARCH!"=="32" goto :arch_ok
    if "!DLL_ARCH!"=="64" goto :arch_ok
)
echo.

echo   请选择通达信版本:
echo   32 = 32位通达信, 64 = 64位通达信
set "ARCH_INPUT="
set /p "ARCH_INPUT=  请输入 32 或 64: "
if "!ARCH_INPUT!"=="32" (set "DLL_ARCH=32" & goto :arch_ok)
if "!ARCH_INPUT!"=="64" (set "DLL_ARCH=64" & goto :arch_ok)
echo   输入无效
echo.
pause
exit /b 1

:arch_ok
echo.
REM === Step 2: Find TDX installation directory ===
echo [步骤2] 查找 !DLL_ARCH! 位通达信安装目录
echo.
call :find_tdx_dir

if "!TDX_DIR!"=="" goto :tdx_not_found
echo.

REM === Step 3: Close TDX if running, then install files ===
echo [步骤3] 安装插件到通达信目录 [目标: !TDX_DIR!]
echo.

set "RETRY=0"
:check_tdx_running
tasklist /fi "imagename eq !TDX_EXE!" 2>nul | find /i "!TDX_EXE!" >nul
if !ERRORLEVEL! NEQ 0 goto :tdx_closed
set /a RETRY+=1
if !RETRY! GTR 3 (
    echo   通达信未关闭, 安装终止
    echo   请先关闭通达信后再运行本脚本
    echo.
    pause
    exit /b 1
)
echo [LOG] TDX running, retry !RETRY!/3 >> "!LOG_FILE!" 2>nul
echo   通达信正在运行, 请关闭后按任意键重试 (!RETRY!/3)
pause >nul
goto :check_tdx_running

:tdx_closed
echo [LOG] TDX not running (or closed) - proceed >> "!LOG_FILE!" 2>nul
set "TDX_DLLS_DIR=!TDX_DIR!\!TDX_DLLS_SUBDIR!"
set "TDX_PLUGIN_DIR=!TDX_DIR!\!TDX_PLUGIN_SUBDIR!"

if not exist "!TDX_DLLS_DIR!" mkdir "!TDX_DLLS_DIR!" 2>nul
if not exist "!TDX_DLLS_DIR!" (
    echo [LOG] ERROR: mkdir failed: !TDX_DLLS_DIR! >> "!LOG_FILE!" 2>nul
    echo   创建 !TDX_DLLS_SUBDIR! 目录 ... [失败]
    echo   可能是 TDX 安装目录有写入保护, 请检查通达信安装目录权限
    echo.
    pause
    exit /b 1
)
if not exist "!TDX_PLUGIN_DIR!" mkdir "!TDX_PLUGIN_DIR!" 2>nul
if not exist "!TDX_PLUGIN_DIR!" (
    echo [LOG] ERROR: mkdir failed: !TDX_PLUGIN_DIR! >> "!LOG_FILE!" 2>nul
    echo   创建 !TDX_PLUGIN_SUBDIR! 目录 ... [失败]
    echo   可能是 TDX 安装目录有写入保护, 请检查通达信安装目录权限
    echo.
    pause
    exit /b 1
)

REM --- Add Defender exclusion paths to allow DLL copy ---
REM Without this, Windows Defender may block copy of unsigned PE files.
REM Only affects: DLL source dir + TDX target dirs (already user-trusted).
REM Silently skipped if Add-MpPreference fails (e.g. third-party AV, no PS).
set "_DLL_DIR="
for %%I in ("!DLL_FILE!") do set "_DLL_DIR=%%~dpI"
if "!_DLL_DIR:~-1!"=="\" set "_DLL_DIR=!_DLL_DIR:~0,-1!"
powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; Add-MpPreference -ExclusionPath '!_DLL_DIR!' -Force; Add-MpPreference -ExclusionPath '!TDX_DLLS_DIR!' -Force; Add-MpPreference -ExclusionPath '!TDX_PLUGIN_DIR!' -Force" >nul 2>&1
echo [LOG] Defender exclusion requested (rc=!errorlevel!) >> "!LOG_FILE!" 2>nul
echo   -- 复制到 !TDX_DLLS_SUBDIR! --
if "!HAS_DLL!"=="1" call :install_file "!DLL_FILE!" "!TDX_DLLS_DIR!\!DLL_NAME!"
if "!HAS_INI!"=="1" call :install_file "!INI_FILE!" "!TDX_DLLS_DIR!\!INI_NAME!"
if "!HAS_TN6!"=="1" call :install_file "!TN6_FILE!" "!TDX_DLLS_DIR!\!TN6_NAME!"
if "!HAS_LIC!"=="1" call :install_file "!LIC_FILE!" "!TDX_DLLS_DIR!\!LIC_NAME!"
echo.

echo   -- 复制到 !TDX_PLUGIN_SUBDIR! --
if "!HAS_DLL!"=="1" call :install_file "!DLL_FILE!" "!TDX_PLUGIN_DIR!\!DLL_NAME!"
if "!HAS_LIC!"=="1" call :install_file "!LIC_FILE!" "!TDX_PLUGIN_DIR!\!LIC_NAME!"
echo.

echo [步骤4] 校验安装文件
echo.
echo   -- 校验 !TDX_DLLS_SUBDIR! --
if "!HAS_DLL!"=="1" call :verify_file "!DLL_FILE!" "!TDX_DLLS_DIR!\!DLL_NAME!"
if "!HAS_INI!"=="1" call :verify_file "!INI_FILE!" "!TDX_DLLS_DIR!\!INI_NAME!"
if "!HAS_TN6!"=="1" call :verify_file "!TN6_FILE!" "!TDX_DLLS_DIR!\!TN6_NAME!"
if "!HAS_LIC!"=="1" call :verify_file "!LIC_FILE!" "!TDX_DLLS_DIR!\!LIC_NAME!"
echo.
echo   -- 校验 !TDX_PLUGIN_SUBDIR! --
if "!HAS_DLL!"=="1" call :verify_file "!DLL_FILE!" "!TDX_PLUGIN_DIR!\!DLL_NAME!"
if "!HAS_LIC!"=="1" call :verify_file "!LIC_FILE!" "!TDX_PLUGIN_DIR!\!LIC_NAME!"
call :log "Verify summary: total=!VERIFY_TOTAL! failed=!VERIFY_FAIL!"
echo.
if "!VERIFY_FAIL!"=="0" (
    echo   校验结果: 全部 !VERIFY_TOTAL! 个文件通过
) else (
    echo   校验结果: 共 !VERIFY_TOTAL! 个文件, 其中 !VERIFY_FAIL! 个校验失败
)
if "!VERIFY_FAIL!"=="0" goto :install_ok

echo   !VERIFY_FAIL! 个文件校验失败, 安装可能不完整
echo   请参考用户手册手动完成安装
echo.
pause
exit /b 1

:install_ok
echo [LOG] Copy+verify finished: TDX_DIR=!TDX_DIR! arch=!DLL_ARCH! total=!VERIFY_TOTAL! failed=!VERIFY_FAIL! >> "!LOG_FILE!" 2>nul

:install_done
echo.
echo ============================================================
echo   安装/升级完成!
echo ============================================================
echo.
echo   通达信目录: !TDX_DIR! [!DLL_ARCH!位]
echo   - !TDX_DLLS_SUBDIR!\  (主图分析)
echo   - !TDX_PLUGIN_SUBDIR!\      (插件选股)
echo.
echo   使用方法:
echo   1. 启动通达信
echo   2. 用 Ctrl+F 打开公式管理器
echo   3. 重新在通达信中导入 !TN6_NAME! 文件并覆盖同名公式
echo   4. 新装用户：在股票 K 线图里输入 ZEN [回车] 即可看到缠论分析结果
echo.
pause
REM Best-effort cleanup when running from the staged copy in %PUBLIC%
if /i not "!SCRIPT_DIR!"=="%PUBLIC%\zen_install_tmp" goto :skip_stage_clean
cd /d "!TEMP!" 2>nul
(goto) 2>nul & rd /s /q "%PUBLIC%\zen_install_tmp" 2>nul
:skip_stage_clean
exit /b 0

:tdx_not_found
echo [LOG] ERROR: TDX dir not found (arch=!DLL_ARCH!, all strategies exhausted) >> "!LOG_FILE!" 2>nul
echo.
echo [错误] 未找到 !DLL_ARCH! 位通达信安装目录
echo.
echo 已尝试以下查找策略:
echo   策略 1: 检查桌面快捷方式/任务栏/开始菜单
echo   策略 2: 检查标准路径 (new_tdx / new_tdx64)
echo   策略 3: 全盘搜索 !TDX_EXE!
echo.
echo 可能的原因:
echo   - 通达信未安装
echo   - 当前安装包与已安装通达信版本位不匹配
echo.
echo 请参考用户手册手动安装:
echo   1. 将所有文件复制到 !TDX_DLLS_SUBDIR!\ (主图分析): !DLL_NAME! / !INI_NAME! / !TN6_NAME! / !LIC_NAME!
echo   2. 将 !DLL_NAME! 与 !LIC_NAME! 同时复制到 !TDX_PLUGIN_SUBDIR!\
echo       (与 T0002 平行的目录, 没有则手工新建)
echo   3. 在通达信公式管理器中导入 !TN6_NAME!
echo.
pause
exit /b 1

REM ============================================================
REM ============ Functions below, not in main flow =============
REM ============================================================

:detect_arch
REM Detect EXE machine type (32/64-bit) via GetBinaryType (kernel32).
REM The OS's own binary-classification API - no byte dumping. EXE ONLY:
REM GetBinaryType rejects DLL images by design (user-verified on Win10/11),
REM so DLL files must go through :detect_dll_arch instead.
REM no certutil, no temp hex files. Works on Windows XP - 11.
REM Returns 32 / 64 / unknown. On 32-bit Windows a 64-bit PE reports
REM unknown (64-bit TDX cannot run there anyway) and the caller falls
REM back to the manual 32/64 prompt. ~1-2s per call (PowerShell spawn).
REM Args: %1=file path, %2=output variable name
set "_ARCH_FILE=%~1"
set "_OUT_VAR=%~2"
set "!_OUT_VAR!=unknown"
set "_ARCH_RES="
set "_ARCH_PS1=%TEMP%\zen_arch_%RANDOM%.ps1"
set "_ARCH_OUT=%TEMP%\zen_arch_%RANDOM%.txt"
> "!_ARCH_PS1!" echo param([string]$File,[string]$OutFile)
>> "!_ARCH_PS1!" echo Add-Type -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool GetBinaryType(string lpApplicationName, out uint lpBinaryType);' -Name ZenBin -Namespace Win32
>> "!_ARCH_PS1!" echo $b=[uint32]0; $r='unknown'
>> "!_ARCH_PS1!" echo if ([Win32.ZenBin]::GetBinaryType($File, [ref]$b)) { if ($b -eq 0) { $r='32' } elseif ($b -eq 6) { $r='64' } }
>> "!_ARCH_PS1!" echo [IO.File]::WriteAllText($OutFile, $r)
powershell -NoProfile -ExecutionPolicy Bypass -File "!_ARCH_PS1!" "!_ARCH_FILE!" "!_ARCH_OUT!" >nul 2>&1
del "!_ARCH_PS1!" >nul 2>&1
if not exist "!_ARCH_OUT!" (
    call :log "detect_arch(GetBinaryType): NO RESULT (PS failed) for !_ARCH_FILE!"
    exit /b 0
)
for /f "usebackq delims=" %%z in ("!_ARCH_OUT!") do set "_ARCH_RES=%%z"
call :log "detect_arch(GetBinaryType): !_ARCH_FILE! = !_ARCH_RES!"
del "!_ARCH_OUT!" >nul 2>&1
if not "!_ARCH_RES!"=="" set "!_OUT_VAR!=!_ARCH_RES!"
exit /b 0
:detect_dll_arch
REM Detect DLL architecture by parsing the PE header Machine field.
REM GetBinaryType cannot classify DLL images (by design), so for DLLs we
REM read bytes in-memory via PowerShell - a native system component, no
REM dump file is written, no third-party tool involved. Any failure
REM returns 'unknown' and the caller falls back to the manual 32/64
REM prompt, so a wrong-arch install can never happen.
REM Args: %1=file path, %2=output variable name
set "_ARCH_FILE=%~1"
set "_OUT_VAR=%~2"
set "!_OUT_VAR!=unknown"
set "_ARCH_RES="
set "_ARCH_PS1=%TEMP%\zen_arch_%RANDOM%.ps1"
set "_ARCH_OUT=%TEMP%\zen_arch_%RANDOM%.txt"
> "!_ARCH_PS1!" echo param([string]$File,[string]$OutFile)
>> "!_ARCH_PS1!" echo try { $b=[IO.File]::ReadAllBytes($File) } catch { exit 1 }
>> "!_ARCH_PS1!" echo $m=[BitConverter]::ToUInt16($b,[BitConverter]::ToUInt32($b,0x3C)+4)
>> "!_ARCH_PS1!" echo $r='unknown'
>> "!_ARCH_PS1!" echo if ($m -eq 0x8664) { $r='64' } elseif ($m -eq 0x014C) { $r='32' }
>> "!_ARCH_PS1!" echo [IO.File]::WriteAllText($OutFile, $r)
powershell -NoProfile -ExecutionPolicy Bypass -File "!_ARCH_PS1!" "!_ARCH_FILE!" "!_ARCH_OUT!" >nul 2>&1
del "!_ARCH_PS1!" >nul 2>&1
if not exist "!_ARCH_OUT!" (
    call :log "detect_dll_arch: NO RESULT (PS failed) for !_ARCH_FILE!"
    exit /b 0
)
for /f "usebackq delims=" %%z in ("!_ARCH_OUT!") do set "_ARCH_RES=%%z"
call :log "detect_dll_arch: !_ARCH_FILE! = !_ARCH_RES!"
del "!_ARCH_OUT!" >nul 2>&1
if not "!_ARCH_RES!"=="" set "!_OUT_VAR!=!_ARCH_RES!"
exit /b 0
:install_file
REM Copy one file and report status. Path field is auto-fitted to the
REM console width; drive letter and first directory are always kept
REM in full, so status brackets align vertically.
REM Args: %1=source, %2=destination
set "_I_SRC=%~1"
set "_I_DST=%~2"
call :fit_path "!_I_DST!" !PATH_W!
copy /Y "!_I_SRC!" "!_I_DST!" >nul 2>&1
if errorlevel 1 (
    call :log "COPY FAILED rc=!ERRORLEVEL!: !_I_SRC! => !_I_DST!"
    echo     !_FP! [复制失败]
    exit /b 0
)
call :log "COPY OK: !_I_DST!"
echo     !_FP! [完成]
exit /b 0

:verify_file
REM Byte-compare source vs destination (fc /b) and report. Path field
REM fitted to console width, bracket column aligned with copy step.
REM Args: %1=source, %2=destination
set "_I_SRC=%~1"
set "_I_DST=%~2"
call :fit_path "!_I_DST!" !PATH_W!
set /a VERIFY_TOTAL+=1
if not exist "!_I_DST!" (
    call :log "VERIFY FAILED: target missing: !_I_DST!"
    echo     !_FP! [校验失败 目标缺失]
    set /a VERIFY_FAIL+=1
    exit /b 0
)
fc /b "!_I_SRC!" "!_I_DST!" >nul 2>&1
if errorlevel 1 (
    call :log "VERIFY FAILED (content mismatch): !_I_SRC! vs !_I_DST!"
    echo     !_FP! [校验失败]
    set /a VERIFY_FAIL+=1
) else (
    call :log "VERIFY OK: !_I_DST!"
    echo     !_FP! [通过]
)
exit /b 0

:fit_path
Rem %1=path %2=max display width. Sets _FP: exactly %2 columns.
Rem Drive + first directory always shown in full (through the 2nd
Rem backslash, 4th for UNC); the rest is shortened with ... before
Rem the tail. Fits-but-shorter paths are space-padded to %2.
set "S=%~1"
set /a FPW=%~2
set /a LEN=0
:fit_len
if !LEN! GTR !FPW! goto :fit_eval
if not "!S:~%LEN%,1!"=="" (
    set /a LEN+=1
    goto :fit_len
)
:fit_eval
set "_FP=!S!!PADSP!"
set "_FP=!_FP:~0,%FPW%!"
if !LEN! LEQ !FPW! exit /b 0
set /a CUT=0
set /a BSN=2
if "!S:~1,1!"=="\" set /a BSN=4
:fit_seg
if !BSN! LEQ 0 goto :fit_seg_done
if "!S:~%CUT%,1!"=="" goto :fit_seg_done
if "!S:~%CUT%,1!"=="\" set /a BSN-=1
set /a CUT+=1
goto :fit_seg
:fit_seg_done
set /a HLEN=CUT
set /a TLEN=FPW-HLEN-3
if !TLEN! LSS 1 (
    set "_FP=!S:~0,%HLEN%!!PADSP!"
    set "_FP=!_FP:~0,%FPW%!"
    exit /b 0
)
set "_FP=!S:~0,%HLEN%!...!S:~-%TLEN%!"
exit /b 0

:get_width
Rem Detect console width via [Console]::WindowWidth; fallback 80.
Rem PATH_W = width minus: 4-space indent, 1 space, longest status
Rem ([校验失败 目标缺失] = 19 columns) and 1 column of margin.
set "_CONW=80"
for /f %%w in ('powershell -NoProfile -Command "try{[Console]::WindowWidth}catch{exit 1}" 2^>nul') do set "_CONW=%%w"
set /a PATH_W=_CONW-25
if !PATH_W! LSS 20 set "PATH_W=20"
call :log "Console width=!_CONW! PATH_W=!PATH_W!"
exit /b 0
:log
REM %1 = single quoted English message. Redirect-first form avoids
REM the "trailing digit eats the redirect" cmd parsing bug.
>> "!LOG_FILE!" 2>nul echo [%DATE% %TIME%] %~1
exit /b 0

:check_tdx_candidate
REM Check candidate dir: has tdxw.exe with matching arch
set "_CAND_DIR=%~1"
set "_CAND_FOUND=0"
if not exist "!_CAND_DIR!\!TDX_EXE!" exit /b 0
call :log "TDX candidate: !_CAND_DIR!"
set "_CAND_ARCH=unknown"
call :detect_arch "!_CAND_DIR!\!TDX_EXE!" _CAND_ARCH
call :log "tdxw.exe arch: !_CAND_ARCH! (DLL is !DLL_ARCH!)"
call set "_CAND_VAL=%%_CAND_ARCH%%"
if "!_CAND_VAL!"=="!DLL_ARCH!" (
    set "TDX_DIR=!_CAND_DIR!"
    set "_CAND_FOUND=1"
)
exit /b 0

:find_tdx_dir
REM Find TDX installation directory
set "TDX_DIR="

powershell -NoProfile -Command "Write-Host '  策略 1: 检查桌面快捷方式/任务栏/开始菜单... ' -NoNewline"
call :find_tdx_from_shortcut
if not "!TDX_DIR!"=="" goto :find_done
echo [未找到]

powershell -NoProfile -Command "Write-Host '  策略 2: 检查标准路径(new_tdx / new_tdx64)... ' -NoNewline"
for %%D in (C D E F G H I J K) do (
    if "!TDX_DIR!"=="" call :check_tdx_candidate "%%D:\new_tdx"
    if "!TDX_DIR!"=="" call :check_tdx_candidate "%%D:\new_tdx64"
)
call :check_tdx_candidate "%ProgramFiles%\new_tdx"
if not "!TDX_DIR!"=="" goto :find_done
call :check_tdx_candidate "%ProgramFiles%\new_tdx64"
if not "!TDX_DIR!"=="" goto :find_done
call :check_tdx_candidate "%ProgramFiles(x86)%\new_tdx"
if not "!TDX_DIR!"=="" goto :find_done
call :check_tdx_candidate "%ProgramFiles(x86)%\new_tdx64"
if "!TDX_DIR!"=="" echo [未找到]
if not "!TDX_DIR!"=="" goto :find_done

echo.
powershell -NoProfile -Command "Write-Host '  策略 3: 全盘搜索 !TDX_EXE!(请耐心等待, 可能较慢)... ' -NoNewline"
for %%D in (C D E F G H I J K) do (
    if "!TDX_DIR!"=="" if exist "%%D:\" (
        for /f "delims=" %%F in ('dir /s /b "%%D:\!TDX_EXE!" 2^>nul') do (
            if "!TDX_DIR!"=="" (
                for %%P in ("%%~dpF") do set "_FOUND_DIR=%%~dpP"
                if "!_FOUND_DIR:~-1!"=="\" set "_FOUND_DIR=!_FOUND_DIR:~0,-1!"
                call :check_tdx_candidate "!_FOUND_DIR!"
            )
        )
    )
)
if "!TDX_DIR!"=="" echo [未找到]

:find_done
if not "!TDX_DIR!"=="" echo [找到 !DLL_ARCH! 位: !TDX_DIR!]
exit /b 0

:find_tdx_from_shortcut
REM 搜索范围: 当前用户/所有用户 桌面+开始菜单(两层), 当前用户任务栏固定项

REM -- Batch-resolve shortcuts via PowerShell script file --
REM (inline -Command is fragile through cmd quoting; -File avoids that)
set "SC_RESULT=%TEMP%\zen_sc_result_%RANDOM%.txt"
set "SC_PS1=%TEMP%\zen_sc_%RANDOM%.ps1"

> "!SC_PS1!" echo param([string]$Exe,[string]$OutFile,[string]$LogFile)
>> "!SC_PS1!" echo $shell = New-Object -ComObject WScript.Shell
>> "!SC_PS1!" echo $dirs = @("$env:USERPROFILE\Desktop","$env:PUBLIC\Desktop","$env:APPDATA\Microsoft\Windows\Start Menu","$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu","$env:APPDATA\Microsoft\Internet Explorer\Quick Launch")
>> "!SC_PS1!" echo $hits = New-Object System.Collections.Generic.List[string]
>> "!SC_PS1!" echo foreach ($d in $dirs) {
>> "!SC_PS1!" echo   if (-not (Test-Path -LiteralPath $d)) { Add-Content -Path $LogFile -Value "SC dir missing: $d"; continue }
>> "!SC_PS1!" echo   $files = @(Get-ChildItem -LiteralPath $d -Recurse -Filter *.lnk -Force -ErrorAction SilentlyContinue)
>> "!SC_PS1!" echo   Add-Content -Path $LogFile -Value ("SC dir {0} files={1}" -f $d, $files.Length)
>> "!SC_PS1!" echo   foreach ($f in $files) {
>> "!SC_PS1!" echo     try { $t = $shell.CreateShortcut($f.FullName).TargetPath } catch { $t = ''; Add-Content -Path $LogFile -Value "SC err: $($f.FullName)" }
>> "!SC_PS1!" echo     if ($t -and $t.ToLower().Contains($Exe)) { $hits.Add($t) }
>> "!SC_PS1!" echo   }
>> "!SC_PS1!" echo }
>> "!SC_PS1!" echo Add-Content -Path $LogFile -Value ("SC total hits=" + $hits.Count)
>> "!SC_PS1!" echo Set-Content -Path $OutFile -Value $hits

powershell -NoProfile -ExecutionPolicy Bypass -File "!SC_PS1!" "!TDX_EXE!" "!SC_RESULT!" "!LOG_FILE!" >nul 2>&1
echo [LOG] SC ps1 rc=!ERRORLEVEL! >> "!LOG_FILE!" 2>nul
type "!SC_RESULT!" >> "!LOG_FILE!" 2>nul
echo [LOG] SC result end >> "!LOG_FILE!" 2>nul
del "!SC_PS1!" >nul 2>&1

if not exist "!SC_RESULT!" exit /b 0
for /f "usebackq delims=" %%a in ("!SC_RESULT!") do (
    if "!TDX_DIR!"=="" (
        set "SHORTCUT_TARGET=%%a"
        for %%F in ("%%a") do set "SHORTCUT_DIR=%%~dpF"
        if "!SHORTCUT_DIR:~-1!"=="\" set "SHORTCUT_DIR=!SHORTCUT_DIR:~0,-1!"
        if exist "!SHORTCUT_DIR!\!TDX_EXE!" (
            call :check_tdx_candidate "!SHORTCUT_DIR!"
        )
    )
)
del "!SC_RESULT!" >nul 2>&1
exit /b 0

REM ============================================================
REM Safety net: if we reach here, main flow missed an exit point
REM ============================================================
echo.
echo [信息] 安装程序执行完毕
echo.
pause
exit /b 0
