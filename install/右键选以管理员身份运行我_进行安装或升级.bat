@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
goto :main

REM ============================================================
REM  Zen Plugin - TDX DLL Installer/Upgrader
REM  OS: Windows 7 ~ Windows 11, 32-bit/64-bit
REM  Encoding: GBK (chcp 936). Do NOT re-encode to UTF-8.
REM ============================================================

:main
set "LOG_FILE=%TEMP%\zen_install.log"
echo ============================================================ > "!LOG_FILE!" 2>nul
echo Zen Plugin Install Log - %DATE% %TIME% >> "!LOG_FILE!" 2>nul
echo ============================================================ >> "!LOG_FILE!" 2>nul
echo [LOG] Script started >> "!LOG_FILE!" 2>nul
echo [LOG] %~f0 >> "!LOG_FILE!" 2>nul

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
    echo 请将插件文件与本脚本放在同一目录后重试
    echo 详情已记录到: !LOG_FILE!
    pause
    exit /b 1
)

echo [LOG] Install files accessible, continuing >> "!LOG_FILE!" 2>nul

set "DLL_FILE=!SCRIPT_DIR!\!DLL_NAME!"
set "INI_FILE=!SCRIPT_DIR!\!INI_NAME!"
set "TN6_FILE=!SCRIPT_DIR!\!TN6_NAME!"
set "LIC_FILE=!SCRIPT_DIR!\!LIC_NAME!"
set "DLL_ARCH=unknown"
set "TDX_DIR="
set "VERIFY_FAIL=0"

echo.
echo ============================================================
echo   禅中看禅 - 通达信 DLL 插件安装/升级
echo ============================================================
echo.

REM === Step 1: 检查安装文件 ===
echo [步骤1] 检查安装文件
echo.

set "HAS_DLL=0"
set "HAS_INI=0"
set "HAS_TN6=0"
set "HAS_LIC=0"

if exist "!DLL_FILE!" (
    set "HAS_DLL=1"
    echo   %DLL_NAME% ... [找到]
) else (
    echo   %DLL_NAME% ... [缺失]
)

if exist "!INI_FILE!" (
    set "HAS_INI=1"
    echo   %INI_NAME% ... [找到]
) else (
    echo   %INI_NAME% ... [缺失]
)

if exist "!TN6_FILE!" (
    set "HAS_TN6=1"
    echo   %TN6_NAME% ... [找到]
) else (
    echo   %TN6_NAME% ... [缺失]
)

if exist "!LIC_FILE!" (
    set "HAS_LIC=1"
    echo   %LIC_NAME% ... [授权文件]
) else (
    echo   %LIC_NAME% ... [无 - 试用模式]
)
echo.

REM === Step 1b: Determine target TDX architecture ===
if "!HAS_DLL!"=="1" (
    call :detect_arch "!DLL_FILE!" DLL_ARCH
    if "!DLL_ARCH!"=="32" goto :arch_ok
    if "!DLL_ARCH!"=="64" goto :arch_ok
)

echo   请选择通达信版本:
echo   32 = 32位通达信, 64 = 64位通达信
set "ARCH_INPUT="
set /p "ARCH_INPUT=  请输入 32 或 64: "
if "!ARCH_INPUT!"=="32" set "DLL_ARCH=32" & goto :arch_ok
if "!ARCH_INPUT!"=="64" set "DLL_ARCH=64" & goto :arch_ok
echo   输入无效
echo.
pause
exit /b 1

:arch_ok
echo   目标版本: !DLL_ARCH!位通达信
echo.

REM === Step 2: Find TDX installation directory ===
echo [步骤2] 查找 !DLL_ARCH! 位通达信安装目录
call :find_tdx_dir

if "!TDX_DIR!"=="" goto :tdx_not_found
echo.

REM === Step 3: Close TDX if running, then install files ===
echo [步骤3] 安装插件到通达信目录
echo   目标: !TDX_DIR!
echo.

set "RETRY=0"
:check_tdx_running
tasklist /fi "imagename eq !TDX_EXE!" 2>nul | find /i "!TDX_EXE!" >nul
if !ERRORLEVEL! NEQ 0 goto :tdx_closed
set /a RETRY+=1
if !RETRY! GTR 3 (
    echo   通达信未关闭, 安装中止
    echo   请先关闭通达信后重新运行此脚本
    echo.
    pause
    exit /b 1
)
echo   通达信正在运行, 请关闭后按任意键继续 (!RETRY!/3)
pause >nul
goto :check_tdx_running

:tdx_closed
set "TDX_DLLS_DIR=!TDX_DIR!\!TDX_DLLS_SUBDIR!"
set "TDX_PLUGIN_DIR=!TDX_DIR!\!TDX_PLUGIN_SUBDIR!"

if not exist "!TDX_DLLS_DIR!" mkdir "!TDX_DLLS_DIR!" 2>nul
if not exist "!TDX_DLLS_DIR!" (
    echo   创建 !TDX_DLLS_SUBDIR! 目录 ... [失败]
    echo   权限不足, 请右键以管理员身份运行
    echo.
    pause
    exit /b 1
)
if not exist "!TDX_PLUGIN_DIR!" mkdir "!TDX_PLUGIN_DIR!" 2>nul
if not exist "!TDX_PLUGIN_DIR!" (
    echo   创建 !TDX_PLUGIN_SUBDIR! 目录 ... [失败]
    echo   权限不足, 请右键以管理员身份运行
    echo.
    pause
    exit /b 1
)

echo   -- 复制到 !TDX_DLLS_SUBDIR! --
if "!HAS_DLL!"=="1" call :install_file "!DLL_FILE!" "!TDX_DLLS_DIR!\!DLL_NAME!"
if "!HAS_INI!"=="1" call :install_file "!INI_FILE!" "!TDX_DLLS_DIR!\!INI_NAME!"
if "!HAS_TN6!"=="1" call :install_file "!TN6_FILE!" "!TDX_DLLS_DIR!\!TN6_NAME!"
if "!HAS_LIC!"=="1" call :install_file "!LIC_FILE!" "!TDX_DLLS_DIR!\!LIC_NAME!"

echo   -- 复制到 !TDX_PLUGIN_SUBDIR! --
if "!HAS_DLL!"=="1" call :install_file "!DLL_FILE!" "!TDX_PLUGIN_DIR!\!DLL_NAME!"
if "!HAS_LIC!"=="1" call :install_file "!LIC_FILE!" "!TDX_PLUGIN_DIR!\!LIC_NAME!"

if "!VERIFY_FAIL!"=="0" goto :install_ok

echo   !VERIFY_FAIL! 个文件校验失败, 安装可能不完整
echo   请参考用户手册手动完成安装
echo.
pause
exit /b 1

:install_ok
echo   全部文件安装校验通过

:install_done
echo.
echo ============================================================
echo   安装/升级完成!
echo ============================================================
echo.
echo   通达信目录: !TDX_DIR! [!DLL_ARCH!位]
echo   - !TDX_DLLS_SUBDIR!\  主图分析
echo   - !TDX_PLUGIN_SUBDIR!\       插件选股
echo.
echo   后续操作:
echo   1. 启动通达信
echo   2. 按 Ctrl+F 打开公式管理器
echo   3. 导入 !TN6_NAME! 公式文件
echo   4. 在主图中输入公式名 ZEN 进行缠论分析
echo.
pause
exit /b 0

:tdx_not_found
echo.
echo [错误] 未找到 !DLL_ARCH! 位通达信安装目录
echo.
echo 已尝试以下查找策略:
echo   策略1: 检查桌面/开始菜单快捷方式
echo   策略2: 检查标准路径 (new_tdx / new_tdx64)
echo   策略3: 递归搜索各盘 !TDX_EXE!
echo.
echo 可能的原因:
echo   - 通达信未安装
echo   - 当前插件位数与已安装通达信位数不匹配
echo.
echo 请参考用户手册手动安装:
echo   1. 将以下文件复制到 !TDX_DLLS_SUBDIR!\ (主图分析):
      !DLL_NAME! / !INI_NAME! / !TN6_NAME! / !LIC_NAME!
echo   2. 将 !DLL_NAME! 和 !LIC_NAME! 同时复制到 !TDX_PLUGIN_SUBDIR!\
      (与 T0002 平行的目录, 没有则手工新建)
echo   3. 在通达信公式管理器中导入 !TN6_NAME!
echo.
pause
exit /b 1

REM ============================================================
REM ============ Functions below, not in main flow =============
REM ============================================================

:detect_arch
REM Detect DLL architecture (32/64-bit) via PE header using VBS
REM Args: %1=file path, %2=output variable name
set "_ARCH_FILE=%~1"
set "_OUT_VAR=%~2"
set "ARCH_VBS=%TEMP%\zen_arch_%RANDOM%.vbs"
> "!ARCH_VBS!" echo Set stream = CreateObject^("ADODB.Stream"^)
>> "!ARCH_VBS!" echo stream.Type = 1
>> "!ARCH_VBS!" echo stream.Open
>> "!ARCH_VBS!" echo stream.LoadFromFile WScript.Arguments^(0^)
>> "!ARCH_VBS!" echo stream.Position = 60
>> "!ARCH_VBS!" echo Dim b4: b4 = stream.Read^(4^)
>> "!ARCH_VBS!" echo Dim pe_off: pe_off = AscB^(MidB^(b4,1,1^)^) + AscB^(MidB^(b4,2,1^)^)*256 + AscB^(MidB^(b4,3,1^)^)*65536 + AscB^(MidB^(b4,4,1^)^)*16777216
>> "!ARCH_VBS!" echo stream.Position = pe_off + 4
>> "!ARCH_VBS!" echo Dim m2: m2 = stream.Read^(2^)
>> "!ARCH_VBS!" echo Dim m: m = AscB^(MidB^(m2,1,1^)^) + AscB^(MidB^(m2,2,1^)^)*256
>> "!ARCH_VBS!" echo stream.Close
>> "!ARCH_VBS!" echo If m = 332 Then WScript.Echo "32"
>> "!ARCH_VBS!" echo If m = 34404 Then WScript.Echo "64"
if not exist "!ARCH_VBS!" exit /b 0
for /f "tokens=*" %%a in ('cscript //nologo "!ARCH_VBS!" "!_ARCH_FILE!" 2^>nul') do set "!_OUT_VAR!=%%a"
del "!ARCH_VBS!" >nul 2>&1
exit /b 0

:install_file
REM Copy file and verify with fc /b. Increment VERIFY_FAIL on failure.
REM Args: %1=source, %2=destination
set "_I_SRC=%~1"
set "_I_DST=%~2"
copy /Y "!_I_SRC!" "!_I_DST!" >nul 2>&1
if errorlevel 1 (
    echo     !_I_DST! ... [复制失败]
    set /a VERIFY_FAIL+=1
    exit /b 0
)
fc /b "!_I_SRC!" "!_I_DST!" >nul 2>&1
if errorlevel 1 (
    echo     !_I_DST! ... [校验失败]
    set /a VERIFY_FAIL+=1
) else (
    echo     !_I_DST! ... [OK]
)
exit /b 0

:check_tdx_candidate
REM Check candidate dir: has tdxw.exe with matching arch
set "_CAND_DIR=%~1"
set "_CAND_FOUND=0"
if not exist "!_CAND_DIR!\!TDX_EXE!" exit /b 0
set "_CAND_ARCH=unknown"
call :detect_arch "!_CAND_DIR!\!TDX_EXE!" _CAND_ARCH
call set "_CAND_VAL=%%_CAND_ARCH%%"
if "!_CAND_VAL!"=="!DLL_ARCH!" (
    set "TDX_DIR=!_CAND_DIR!"
    set "_CAND_FOUND=1"
)
exit /b 0

:find_tdx_dir
REM Find TDX installation directory
set "TDX_DIR="

<NUL set /p=   策略1: 检查桌面/开始菜单快捷方式... 
call :find_tdx_from_shortcut
if not "!TDX_DIR!"=="" goto :find_done
echo   [未找到]

<NUL set /p=   策略2: 检查标准路径... 
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
if "!TDX_DIR!"=="" echo   [未找到]
if not "!TDX_DIR!"=="" goto :find_done

<NUL set /p=   策略3: 递归搜索各盘 !TDX_EXE! -- 请耐心等待... 
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
if "!TDX_DIR!"=="" echo   [未找到]

:find_done
if not "!TDX_DIR!"=="" echo   找到 !DLL_ARCH! 位通达信: !TDX_DIR!
exit /b 0

:find_tdx_from_shortcut
REM Find TDX via desktop/start-menu shortcuts
set "ALL_LNK=%TEMP%\zen_all_lnk_%RANDOM%.txt"
del "!ALL_LNK!" >nul 2>&1
for %%P in (
    "!USERPROFILE!\Desktop"
    "!PUBLIC!\Desktop"
    "C:\Users\Public\Desktop"
    "!APPDATA!\Microsoft\Windows\Start Menu\Programs"
    "!ALLUSERSPROFILE!\Microsoft\Windows\Start Menu\Programs"
    "!PROGRAMDATA!\Microsoft\Windows\Start Menu\Programs"
    "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"
    "C:\Documents and Settings\!USERNAME!\Start Menu\Programs"
    "C:\Documents and Settings\All Users\Start Menu\Programs"
) do (
    if exist "%%~P\" (
        dir /s /b "%%~P\*.lnk" 2>nul >>"!ALL_LNK!"
    )
)
if not exist "!ALL_LNK!" exit /b 0

REM -- Batch-resolve shortcuts via VBS --
set "CHK_VBS=%TEMP%\zen_chk_%RANDOM%.vbs"
set "SC_RESULT=%TEMP%\zen_sc_result_%RANDOM%.txt"

> "!CHK_VBS!" echo Set shell = CreateObject^("WScript.Shell"^)
>> "!CHK_VBS!" echo exeName = WScript.Arguments^(0^)
>> "!CHK_VBS!" echo Do Until WScript.StdIn.AtEndOfStream
>> "!CHK_VBS!" echo   lnkPath = Trim^(WScript.StdIn.ReadLine^(^)^)
>> "!CHK_VBS!" echo   If lnkPath ^<^> "" Then
>> "!CHK_VBS!" echo     On Error Resume Next
>> "!CHK_VBS!" echo     Set sc = shell.CreateShortcut^(lnkPath^)
>> "!CHK_VBS!" echo     If Err.Number = 0 Then
>> "!CHK_VBS!" echo       tPath = sc.TargetPath
>> "!CHK_VBS!" echo       If InStr^(1, tPath, exeName, 1^) Then WScript.Echo tPath
>> "!CHK_VBS!" echo     End If
>> "!CHK_VBS!" echo     Err.Clear
>> "!CHK_VBS!" echo     On Error GoTo 0
>> "!CHK_VBS!" echo   End If
>> "!CHK_VBS!" echo Loop

cscript //nologo "!CHK_VBS!" "!TDX_EXE!" < "!ALL_LNK!" > "!SC_RESULT!" 2>nul

del "!CHK_VBS!" >nul 2>&1
del "!ALL_LNK!" >nul 2>&1
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
