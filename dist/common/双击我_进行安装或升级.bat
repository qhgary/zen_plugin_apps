@echo off
REM 清屏: 双击 UNC 路径时 CMD 会在脚本执行前打印路径不受支持的提示, 此处清除, 对用户透明。
REM cls 只清屏幕, 不改变量与日志, 双击新窗口下无副作用。
cls >nul 2>&1
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
REM === 首行提示先于任何前置任务显示, 两个窗口都先显示这一句, 避免 PowerShell 冷启动期间窗口空白 ===
echo.
echo   安装中，请勿关闭本窗口，安装完成会自行关闭，耐心等待...
REM === 日志框架: 工作日志固定在本地公共位置(提权会话一定可达), 结束时保存到安装目录 ===
set "LOG_MODE=overwrite"
if /i "%~1"=="ZEN_ELEVATED" set "LOG_MODE=append"
if /i "%~dp0"=="%PUBLIC%\zen_install_tmp\" set "LOG_MODE=append"
set "WORK_LOG=%PUBLIC%\zen_install.log"
set "LOG_FILE=!WORK_LOG!"
set "LOG_TARGET=%~dp0zen_install.log"
set "LOG_TARGET_UNC="
set "LOG_HINT=%~dp0zen_log_path.txt"
set "DONE_FLAG=%PUBLIC%\zen_install_done.ok"
set "EXIT_FLAG=%PUBLIC%\zen_install_exit.ok"
set "RUN_FLAG=%PUBLIC%\zen_install_running.ok"
set "PARENT_FLAG=%PUBLIC%\zen_install_parent.ok"
set "TIMEOUT_FLAG=%PUBLIC%\zen_install_timeout.ok"
set "LOCK_DIR=%PUBLIC%\zen_install_running.lock"
set "LOCK_OWNER=!LOCK_DIR!\owner.txt"
set "LOCK_HELD=0"
set "HAS_PARENT=0"
if "!LOG_MODE!"=="append" if /i "%~1"=="ZEN_ELEVATED" set "HAS_PARENT=1"
set "IS_PARENT=0"
set "IS_BOOTSTRAP=0"
if /i not "%~1"=="ZEN_ELEVATED" if /i not "%~dp0"=="%PUBLIC%\zen_install_tmp\" set "IS_BOOTSTRAP=1"
set "ELEV_FLAG=%PUBLIC%\zen_install_tmp\elevated.ok"
set "NEED_ELEVATE=1"
if /i "%~1"=="ZEN_ELEVATED" set "NEED_ELEVATE=0"
if /i "%~dp0"=="%PUBLIC%\zen_install_tmp\" set "NEED_ELEVATE=0"
if "!NEED_ELEVATE!"=="1" (
    fltmc >nul 2>&1
    if !ERRORLEVEL! EQU 0 set "NEED_ELEVATE=0"
)
REM 提权副本先回执, 再做进程登记, 避免 PowerShell 冷启动造成父窗口误判。
if "!LOG_MODE!"=="append" if /i "%~1"=="ZEN_ELEVATED" echo.> "%PUBLIC%\zen_install_tmp\elevated.ok" 2>nul
REM 记录 cmd 进程号: 第二个实例可区分活动锁与上次异常结束留下的锁。
set "MY_PID="
for /f %%P in ('powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)).ParentProcessId" 2^>nul') do set "MY_PID=%%P"
if "!HAS_PARENT!"=="1" if not "!MY_PID!"=="" if exist "!LOCK_OWNER!" >> "!LOCK_OWNER!" echo !MY_PID!
REM mkdir 是原子操作; 锁检查早于任何日志写入, 活动锁命中时不碰现有日志。
if "!IS_BOOTSTRAP!"=="1" (
    if "!NEED_ELEVATE!"=="1" set "IS_PARENT=1"
    mkdir "!LOCK_DIR!" 2>nul
    if errorlevel 1 (
        call :lock_is_active
        if "!LOCK_ACTIVE!"=="1" (
            echo.
            echo   [提示] 安装正在运行，请勿重复启动。
            echo   请先关闭已有安装窗口。
            echo.
            pause
            exit /b 1
        )
        rd /s /q "!LOCK_DIR!" >nul 2>&1
        del "!RUN_FLAG!" "!DONE_FLAG!" "!EXIT_FLAG!" "!PARENT_FLAG!" "!TIMEOUT_FLAG!" "!ELEV_FLAG!" >nul 2>&1
        mkdir "!LOCK_DIR!" 2>nul
        if errorlevel 1 (
            echo   [错误] 无法创建安装运行锁，安装终止。
            pause
            exit /b 1
        )
    )
    set "LOCK_HELD=1"
    > "!LOCK_OWNER!" echo !MY_PID!
    echo.> "!RUN_FLAG!" 2>nul
    del "!DONE_FLAG!" "!EXIT_FLAG!" "!PARENT_FLAG!" "!TIMEOUT_FLAG!" "!ELEV_FLAG!" >nul 2>&1
    if "!IS_PARENT!"=="1" > "!PARENT_FLAG!" echo !MY_PID!
)
set "LOG_HINT_READ=0"
if exist "!LOG_HINT!" (
    set "_LN=0"
    for /f "usebackq delims=" %%L in ("!LOG_HINT!") do (
        set /a "_LN+=1"
        if "!_LN!"=="1" set "LOG_TARGET=%%~L"
        if "!_LN!"=="1" set "LOG_HINT_READ=1"
        if "!_LN!"=="2" set "LOG_TARGET_UNC=%%~L"
    )
)
REM 日志与双击的脚本同目录时, 屏幕只提示文件名; 其他位置才显示完整路径
set "LOG_LOCAL=0"
if "!LOG_MODE!"=="overwrite" (
    if /i "!LOG_TARGET!"=="%~dp0zen_install.log" set "LOG_LOCAL=1"
) else (
    if "!LOG_HINT_READ!"=="1" set "LOG_LOCAL=1"
)
set "LOG_DISPLAY=!LOG_TARGET!"
if "!LOG_LOCAL!"=="1" set "LOG_DISPLAY=当前目录下的 zen_install.log"
if "!LOG_MODE!"=="overwrite" (
    del "!LOG_TARGET!" >nul 2>&1
    > "!LOG_FILE!" 2>nul echo ZEN_LOG_PROBE %DATE% %TIME%
    findstr /c:"ZEN_LOG_PROBE" "!LOG_FILE!" >nul 2>&1
    if errorlevel 1 echo   [警告] 公共位置也无法写入日志，本次安装将没有日志记录。
) else (
    >> "!LOG_FILE!" 2>nul echo ZEN_P2_PROBE %DATE% %TIME%
    findstr /c:"ZEN_P2_PROBE" "!LOG_FILE!" >nul 2>&1
    if errorlevel 1 echo   [警告] 公共位置也无法写入日志，本次安装将没有日志记录。
)
if "!LOG_MODE!"=="overwrite" (
    >> "!LOG_FILE!" 2>nul echo ============================================================
    if "!IS_PARENT!"=="1" (
        >> "!LOG_FILE!" 2>nul echo === 段 1 / 2 开始：安装引导窗口，普通权限，用户 !USERNAME! ===
        >> "!LOG_FILE!" 2>nul echo === 本文件由两个窗口依次写入，共两段，不会同时写。 ===
        >> "!LOG_FILE!" 2>nul echo === 安装期间日志暂存在 !WORK_LOG!，提权成功后由安装窗口保存到 !LOG_TARGET! ===
        >> "!LOG_FILE!" 2>nul echo === 安装窗口是高权限会话, 映射盘另走 UNC 备用路径回写, 本地盘直接保存到安装目录。 ===
        >> "!LOG_FILE!" 2>nul echo === 引导窗口在提权成功后立即退出, 日志回写与暂存副本清理均由安装窗口完成, 最终只留安装目录那一份。 ===
        >> "!LOG_FILE!" 2>nul echo === 段 2 有开始、且末尾有 安装记录结束 一行，表示安装流程走完。 ===
        >> "!LOG_FILE!" 2>nul echo === 若段 2 有开始但没有这一行，表示安装中途失败，以最后一条 ERROR 为准。 ===
        >> "!LOG_FILE!" 2>nul echo === 若只有段 1、找不到 段 2 / 2 开始，说明安装窗口没有启动。 ===
        >> "!LOG_FILE!" 2>nul echo === 若引导窗口被提前关闭, 日志可能留在 !WORK_LOG!; 屏幕结束时会给出本次日志的实际位置。 ===
    ) else (
        >> "!LOG_FILE!" 2>nul echo === 段 1 / 1 开始：单进程安装窗口，管理员权限，用户 !USERNAME! ===
        >> "!LOG_FILE!" 2>nul echo === 本次直接以管理员身份运行，没有引导窗口，全部记录由本进程写入。 ===
        >> "!LOG_FILE!" 2>nul echo === 安装期间日志暂存在 !WORK_LOG!，结束后由本进程保存到 !LOG_TARGET! ===
        >> "!LOG_FILE!" 2>nul echo === 保存成功后删除暂存副本，最终只留安装目录那一份。 ===
        >> "!LOG_FILE!" 2>nul echo === 末尾有 安装记录结束 一行，表示安装流程走完；没有则以最后一条 ERROR 为准。 ===
        >> "!LOG_FILE!" 2>nul echo === 若日志未能保存到安装目录，屏幕结束时会给出本次日志的实际位置。 ===
    )
    >> "!LOG_FILE!" 2>nul echo ============================================================
) else (
    >> "!LOG_FILE!" 2>nul echo ============================================================
    if "!HAS_PARENT!"=="1" (
        >> "!LOG_FILE!" 2>nul echo === 段 2 / 2 开始：安装执行窗口，管理员权限，用户 !USERNAME! ===
        >> "!LOG_FILE!" 2>nul echo === 引导窗口已在提权后退出，日志回写与锁释放均由本窗口完成。 ===
    ) else (
        >> "!LOG_FILE!" 2>nul echo === 单进程安装窗口，管理员权限，用户 !USERNAME! ===
        >> "!LOG_FILE!" 2>nul echo === 未检测到引导窗口，以下记录与日志回写均由本进程完成。 ===
    )
    >> "!LOG_FILE!" 2>nul echo ============================================================
)
if "!LOG_MODE!"=="overwrite" (
>> "!LOG_FILE!" 2>nul     echo.
>> "!LOG_FILE!" 2>nul     echo   安装中，请勿关闭本窗口，安装完成会自行关闭，耐心等待...
) else (
>> "!LOG_FILE!" 2>nul     echo.
>> "!LOG_FILE!" 2>nul     echo   安装中，请勿关闭本窗口，安装完成会自行关闭，耐心等待...
)
>> "!LOG_FILE!" 2>nul echo [LOG] 本次运行段: mode=!LOG_MODE! %DATE% %TIME%
>> "!LOG_FILE!" 2>nul echo [LOG] Script started
>> "!LOG_FILE!" 2>nul echo [LOG] OS: %OS% / %PROCESSOR_ARCHITECTURE%
>> "!LOG_FILE!" 2>nul echo [LOG] Args: %~1 %~2 %~3
>> "!LOG_FILE!" 2>nul echo [LOG] CWD: %CD%
>> "!LOG_FILE!" 2>nul echo [LOG] WorkLog: !WORK_LOG!
>> "!LOG_FILE!" 2>nul echo [LOG] LogTarget: !LOG_TARGET!
>> "!LOG_FILE!" 2>nul echo [LOG] LogTargetUNC: !LOG_TARGET_UNC!
>> "!LOG_FILE!" 2>nul echo [LOG] Script: %~f0
ver >> "!LOG_FILE!" 2>nul
call :diag

REM --- PowerShell availability check (auto-install depends on PS) ---
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto :ps_missing
echo [LOG] PS check ok >> "!LOG_FILE!" 2>nul
goto :ps_done
:ps_missing
echo [LOG] PS check FAILED - auto install requires PowerShell >> "!LOG_FILE!" 2>nul
echo [LOG] Expected at: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe >> "!LOG_FILE!" 2>nul
echo.
>> "!LOG_FILE!" 2>nul echo.
    echo [错误] 未检测到 Windows PowerShell 模块, 自动安装无法继续
>> "!LOG_FILE!" 2>nul     echo [错误] 未检测到 Windows PowerShell 模块, 自动安装无法继续
echo.
>> "!LOG_FILE!" 2>nul echo.
    echo PowerShell 是 Windows 系统自带的, 当前系统可能已将其精简或移除
>> "!LOG_FILE!" 2>nul     echo PowerShell 是 Windows 系统自带的, 当前系统可能已将其精简或移除
    echo 请按用户手册 通达信插件安装 一章 下的 "备选:手动安装" 完成安装:
>> "!LOG_FILE!" 2>nul     echo 请按用户手册 通达信插件安装 一章 下的 "备选:手动安装" 完成安装:
    echo   1. 将 tdx_zen.dll dlls.ini tdx_zen.tn6 复制到通达信目录 T0002\dlls\
>> "!LOG_FILE!" 2>nul     echo   1. 将 tdx_zen.dll dlls.ini tdx_zen.tn6 复制到通达信目录 T0002\dlls\
    echo   2. 将 tdx_zen.dll 复制到通达信目录 plugin\ 目录
>> "!LOG_FILE!" 2>nul     echo   2. 将 tdx_zen.dll 复制到通达信目录 plugin\ 目录
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
goto :exit_fail
:ps_done

REM ============================================================
REM Self-elevation bootstrap (double-click friendly)
REM ============================================================
if "!NEED_ELEVATE!"=="0" goto :elevated_ok
echo [LOG] Not elevated, preparing elevation >> "!LOG_FILE!" 2>nul
REM Always stage the payload to a local public dir before elevating:
REM the elevated process may not see network/virtual drives (Z: etc),
REM so the new instance must run from a guaranteed-local path.
set "STAGE_DIR=%PUBLIC%\zen_install_tmp"
if exist "!ELEV_FLAG!" del "!ELEV_FLAG!" >nul 2>&1
echo [LOG] Staging install files to !STAGE_DIR! >> "!LOG_FILE!" 2>nul
attrib -h "!STAGE_DIR!" >nul 2>&1
if exist "!STAGE_DIR!" rd /s /q "!STAGE_DIR!" 2>nul
mkdir "!STAGE_DIR!" 2>nul
attrib +h "!STAGE_DIR!" >nul 2>&1
if errorlevel 1 echo [LOG] ERROR: mkdir staging dir failed >> "!LOG_FILE!" 2>nul
REM 映射盘在提权会话里不可见: 尽量推导出 UNC, 让安装窗口能把日志写回原目录
set "_LOG_UNC="
set "_LOG_ROOT="
for %%A in ("%~dp0.") do set "_LOG_DRV=%%~dA"
set "_LOG_DRV=!_LOG_DRV:~0,1!"
REM 本地固定盘: 提权后必然可见, 无需 UNC 推导。用 goto 跳过(保持下方 ps1 生成行线性, 不进括号块)。
set "_IS_LOCAL_FIXED=1"
set "_SCRIPT_PATH=%~dp0"
REM UNC 路径直达: %~dp0 已是双反斜杠 UNC 形式, LOG_TARGET 已是正确的 UNC, 无需反推盘符, 直接跳过 2 次 PS。
if "!_SCRIPT_PATH:~0,2!"=="\\" set "_IS_LOCAL_FIXED=0"
if "!_SCRIPT_PATH:~0,2!"=="\\" goto :skip_unc
net use 2>nul | findstr /i /r /c:"^ *!_LOG_DRV!:" >nul 2>&1
if not errorlevel 1 set "_IS_LOCAL_FIXED=0"
if "!_IS_LOCAL_FIXED!"=="1" goto :skip_unc
set "_UNC_PS1=!STAGE_DIR!\zen_unc.ps1"
> "!_UNC_PS1!" echo $ErrorActionPreference='SilentlyContinue'
>> "!_UNC_PS1!" echo $d=$args[0]
>> "!_UNC_PS1!" echo $r=''
>> "!_UNC_PS1!" echo try { $r=(Get-ItemProperty ("HKCU:\Network\" + $d) -Name RemotePath).RemotePath } catch {}
>> "!_UNC_PS1!" echo if(-not $r){ try { $r=(Get-PSDrive -Name $d).DisplayRoot } catch {} }
>> "!_UNC_PS1!" echo if(-not $r){ try { $r=(Get-CimInstance Win32_MappedLogicalDisk -Filter ("DeviceID='" + $d + ":'")).ProviderName } catch {} }
>> "!_UNC_PS1!" echo if(-not $r){ $lines=net use ($d + ':'); foreach($x in $lines){ if($x.Contains('\\')){ $r=$x.Substring($x.IndexOf('\')).Trim(); break } } }
>> "!_UNC_PS1!" echo if($r){ Write-Output $r.TrimEnd([char]92) }
for /f "delims=" %%U in ('powershell -NoProfile -ExecutionPolicy Bypass -File "!_UNC_PS1!" "!_LOG_DRV!" 2^>nul') do set "_LOG_ROOT=%%U"
if not "!_LOG_ROOT!"=="" set "_LOG_UNC=!_LOG_ROOT!%~p0zen_install.log"
>> "!LOG_FILE!" 2>nul echo [DIAG] --- 映射盘 UNC 推导: 盘符 !_LOG_DRV! ---
net use >> "!LOG_FILE!" 2>&1
powershell -NoProfile -Command "Get-PSDrive -Name '!_LOG_DRV!' | Select-Object Name,DisplayRoot,Root | Out-String" >> "!LOG_FILE!" 2>&1
>> "!LOG_FILE!" 2>nul echo [DIAG] UNC root="!_LOG_ROOT!" hint="!_LOG_UNC!"
:skip_unc
if "!_SCRIPT_PATH:~0,2!"=="\\" >> "!LOG_FILE!" 2>nul echo [DIAG] UNC 路径直达: LOG_TARGET 已是 UNC, 跳过无效反推, 省 2 次 PS 冷启动
if "!_IS_LOCAL_FIXED!"=="1" >> "!LOG_FILE!" 2>nul echo [DIAG] 本地固定盘 !_LOG_DRV!: 跳过 UNC 推导, 省 2 次 PS 冷启动
> "!STAGE_DIR!\zen_log_path.txt" echo "!LOG_TARGET!"
if not "!_LOG_UNC!"=="" >> "!STAGE_DIR!\zen_log_path.txt" echo "!_LOG_UNC!"
>> "!LOG_FILE!" 2>nul echo [LOG] Log path hint written: "!LOG_TARGET!" UNC="!_LOG_UNC!"
copy /y "%~f0" "!STAGE_DIR!\" >nul 2>&1
if errorlevel 1 echo [LOG] ERROR: copy script to staging failed >> "!LOG_FILE!" 2>nul
for %%F in (tdx_zen.dll dlls.ini tdx_zen.tn6 zen_license.key) do (
    if exist "%~dp0%%F" (
        copy /y "%~dp0%%F" "!STAGE_DIR!\" >nul 2>&1
        if errorlevel 1 echo [LOG] ERROR: staging copy failed: %%F >> "!LOG_FILE!" 2>nul
    )
)
if not exist "!STAGE_DIR!\%~nx0" goto :elevate_fail
if not exist "!STAGE_DIR!\tdx_zen.dll" (
    >> "!LOG_FILE!" 2>nul echo [ERROR] 缺少必需文件 tdx_zen.dll, 安装终止
    echo   [错误] 缺少必需文件 tdx_zen.dll，安装终止。
>> "!LOG_FILE!" 2>nul     echo   [错误] 缺少必需文件 tdx_zen.dll，安装终止。
    goto :exit_fail
)
set "ELEV_TARGET=!STAGE_DIR!\%~nx0"
REM 去掉网络来源标记(MOTW): 避免提权副本启动时再次触发 SmartScreen 的"是否运行此脚本"提示。
REM 去 MOTW 已合并到下方提权命令(单一 PS 进程内顺序执行): 省一次冷启动, errorlevel 语义不变。
echo [LOG] Requesting elevation: !ELEV_TARGET! >> "!LOG_FILE!" 2>nul
echo.
>> "!LOG_FILE!" 2>nul echo.
echo   正在请求管理员权限, 若弹出权限窗口请点 [是]...
>> "!LOG_FILE!" 2>nul echo   正在请求管理员权限, 若弹出权限窗口请点 [是]...
echo.
>> "!LOG_FILE!" 2>nul echo.
>> "!LOG_FILE!" 2>nul echo === 段 1 主体结束：提权成功后下方应紧接 段 2 / 2 开始；若没有，见本文件开头的说明。 ===
powershell -NoProfile -Command "Unblock-File -LiteralPath '!ELEV_TARGET!'; Unblock-File -LiteralPath '%~f0'; Start-Process -FilePath '!ELEV_TARGET!' -ArgumentList 'ZEN_ELEVATED' -Verb RunAs" >nul 2>&1
if errorlevel 1 (set "_ELEV_RC=1") else (set "_ELEV_RC=0")
if "!_ELEV_RC!"=="1" (
    >> "!LOG_FILE!" 2>nul echo [LOG] Elevation request FAILED rc=1
)
if not "!_ELEV_RC!"=="0" (
    echo [LOG] ERROR: elevation request failed or was cancelled by user >> "!LOG_FILE!" 2>nul
    powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('自动提权失败。可能原因:UAC 已禁用, 或系统缺少 PowerShell。本脚本会自动提权, 无需手动右键。', '禅中看缠 - 安装')" >nul 2>&1
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    echo   [提示] 自动提权失败 ^(UAC 已禁用, 或系统缺少 PowerShell^)
>> "!LOG_FILE!" 2>nul     echo   [提示] 自动提权失败 ^(UAC 已禁用, 或系统缺少 PowerShell^)
    echo   解决方法: 在系统设置中启用 UAC, 然后再次双击本脚本
>> "!LOG_FILE!" 2>nul     echo   解决方法: 在系统设置中启用 UAC, 然后再次双击本脚本
    echo   ^(网络盘会自动中转暂存到 %PUBLIC%, 无需手动操作^)
>> "!LOG_FILE!" 2>nul     echo   ^(网络盘会自动中转暂存到 %PUBLIC%, 无需手动操作^)
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    pause
goto :exit_fail
)
REM --- 确认提权副本确实启动 (提权方式不变, 正常机器上 1 秒内命中便按原样退出) ---
set "_ELEV_OK=0"
for /L %%i in (1,1,60) do (
    if exist "!ELEV_FLAG!" set "_ELEV_OK=1"
    if "!_ELEV_OK!"=="1" goto :elev_confirmed
    ping -n 2 127.0.0.1 >nul
)
:elev_confirmed
if "!_ELEV_OK!"=="1" goto :parent_quick_exit
echo [LOG] ERROR: elevated instance did not start within timeout >> "!LOG_FILE!" 2>nul
echo.
>> "!LOG_FILE!" 2>nul echo.
echo   [提示] 未检测到安装窗口启动
>> "!LOG_FILE!" 2>nul echo   [提示] 未检测到安装窗口启动
echo   若屏幕上已出现安装窗口, 可直接关闭本窗口, 安装会继续进行。
>> "!LOG_FILE!" 2>nul echo   若屏幕上已出现安装窗口, 可直接关闭本窗口, 安装会继续进行。
echo   若没有, 请在 UAC 提示中点击 [是]; 或右键本脚本选择 以管理员身份运行。
>> "!LOG_FILE!" 2>nul echo   若没有, 请在 UAC 提示中点击 [是]; 或右键本脚本选择 以管理员身份运行。
echo   本次请求日志: !WORK_LOG!
>> "!LOG_FILE!" 2>nul echo   本次请求日志: !WORK_LOG!
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
REM 副本可能只是启动慢: 不发布日志、不释放锁; 若副本随后启动, 由它自行保存。
del "!PARENT_FLAG!" >nul 2>&1
echo.> "!TIMEOUT_FLAG!" 2>nul
exit /b 1

:parent_quick_exit
REM 单窗口模式: 提权副本已启动, 引导窗口立即退出; 不做等待、日志回写、锁释放。
REM 日志回写与锁释放全部由提权副本完成 (见 elevated_ok 的 LOCK_HELD 与 publish_log)。
del "!PARENT_FLAG!" >nul 2>&1
del "!ELEV_FLAG!" >nul 2>&1
exit /b 0

:elevate_fail
echo [LOG] ERROR: staging elevation target missing - staging incomplete >> "!LOG_FILE!" 2>nul
echo [LOG] Target expected: !STAGE_DIR!\%~nx0 >> "!LOG_FILE!" 2>nul
powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('无法创建临时安装目录, 安装终止。请将整个安装目录拷贝到本地硬盘后再运行。', '禅中看缠 - 安装')" >nul 2>&1
echo.
>> "!LOG_FILE!" 2>nul echo.
echo [错误] 无法创建临时安装目录, 安装终止
>> "!LOG_FILE!" 2>nul echo [错误] 无法创建临时安装目录, 安装终止
echo 请将整个安装目录拷贝到本地硬盘后再运行本脚本
>> "!LOG_FILE!" 2>nul echo 请将整个安装目录拷贝到本地硬盘后再运行本脚本
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
goto :exit_fail

:elevated_ok
REM 单窗口模式: 引导窗口退出后, 由本提权实例持有并释放运行锁。
set "LOCK_HELD=1"
fltmc >nul 2>&1
if errorlevel 1 (
    >> "!LOG_FILE!" 2>nul echo [ERROR] 当前进程未获得管理员权限
    echo   [错误] 当前进程未获得管理员权限，安装终止。
>> "!LOG_FILE!" 2>nul     echo   [错误] 当前进程未获得管理员权限，安装终止。
    goto :exit_fail
)
REM 启动回执已在 :main 开头发出, 副本进程一起来就写, 不受诊断耗时影响
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
        set "LOG_TARGET=!SCRIPT_DIR!\zen_install.log"
        set "LOG_TARGET_UNC="
        set "LOG_LOCAL=1"
        set "LOG_DISPLAY=当前目录下的 zen_install.log"
        echo [LOG] SCRIPT_DIR = !SCRIPT_DIR! >> "!LOG_FILE!" 2>nul
        echo [LOG] LogTarget updated to UNC = !LOG_TARGET! >> "!LOG_FILE!" 2>nul
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
>> "!LOG_FILE!" 2>nul     echo.
    echo [错误] 未找到任何安装文件
>> "!LOG_FILE!" 2>nul     echo [错误] 未找到任何安装文件
    echo 脚本目录: %~dp0
>> "!LOG_FILE!" 2>nul     echo 脚本目录: %~dp0
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    echo 请将所有安装文件与本脚本放在同一目录再运行
>> "!LOG_FILE!" 2>nul     echo 请将所有安装文件与本脚本放在同一目录再运行
    pause
goto :exit_fail
)

echo [LOG] Install files accessible, continuing >> "!LOG_FILE!" 2>nul

set "DLL_FILE=!SCRIPT_DIR!\!DLL_NAME!"
set "INI_FILE=!SCRIPT_DIR!\!INI_NAME!"
set "TN6_FILE=!SCRIPT_DIR!\!TN6_NAME!"
set "LIC_FILE=!SCRIPT_DIR!\!LIC_NAME!"
set "DLL_ARCH=unknown"
set "TDX_DIR="
set "VERIFY_FAIL=0"
set "VERIFY_TOTAL=0"
set "COPY_FAIL=0"
set "COPY_TOTAL=0"
set "EXPECTED_TOTAL=2"
set "PADSP=                                                                                                                                                                "
call :get_width

echo.
>> "!LOG_FILE!" 2>nul echo.
echo ============================================================
>> "!LOG_FILE!" 2>nul echo ============================================================
echo   禅中看缠 - 通达信 DLL 插件安装/升级
>> "!LOG_FILE!" 2>nul echo   禅中看缠 - 通达信 DLL 插件安装/升级
echo ============================================================
>> "!LOG_FILE!" 2>nul echo ============================================================

REM === 步骤1: 检查安装文件 ===
echo [步骤1] 检查安装文件
>> "!LOG_FILE!" 2>nul echo [步骤1] 检查安装文件
echo.
>> "!LOG_FILE!" 2>nul echo.

set "HAS_DLL=0"
set "HAS_INI=0"
set "HAS_TN6=0"
set "HAS_LIC=0"

if exist "!DLL_FILE!" (
    set "HAS_DLL=1"
    call :detect_dll_arch "!DLL_FILE!" DLL_ARCH
    if "!DLL_ARCH!"=="32" (
        echo   %DLL_NAME% ...... [找到] [32 位]
>> "!LOG_FILE!" 2>nul         echo   %DLL_NAME% ...... [找到] [32 位]
    ) else if "!DLL_ARCH!"=="64" (
        echo   %DLL_NAME% ...... [找到] [64 位]
>> "!LOG_FILE!" 2>nul         echo   %DLL_NAME% ...... [找到] [64 位]
    ) else (
        echo   %DLL_NAME% ...... [找到]
>> "!LOG_FILE!" 2>nul         echo   %DLL_NAME% ...... [找到]
    )
) else (
    echo   %DLL_NAME% ...... [缺失]
>> "!LOG_FILE!" 2>nul     echo   %DLL_NAME% ...... [缺失]
)

if exist "!INI_FILE!" (
    set "HAS_INI=1"
    echo   %INI_NAME% ......... [找到]
>> "!LOG_FILE!" 2>nul     echo   %INI_NAME% ......... [找到]
) else (
    echo   %INI_NAME% ......... [缺失 - 可选, 跳过]
>> "!LOG_FILE!" 2>nul     echo   %INI_NAME% ......... [缺失 - 可选, 跳过]
)

if exist "!TN6_FILE!" (
    set "HAS_TN6=1"
    echo   %TN6_NAME% ...... [找到]
>> "!LOG_FILE!" 2>nul     echo   %TN6_NAME% ...... [找到]
) else (
    echo   %TN6_NAME% ...... [缺失 - 可选, 跳过]
>> "!LOG_FILE!" 2>nul     echo   %TN6_NAME% ...... [缺失 - 可选, 跳过]
)

if exist "!LIC_FILE!" (
    set "HAS_LIC=1"
    echo   %LIC_NAME% .. [授权文件]
>> "!LOG_FILE!" 2>nul     echo   %LIC_NAME% .. [授权文件]
) else (
    echo   %LIC_NAME% .. [无 - 未授权文件]
>> "!LOG_FILE!" 2>nul     echo   %LIC_NAME% .. [无 - 未授权文件]
)

echo [LOG] Files: DLL=!HAS_DLL! INI=!HAS_INI! TN6=!HAS_TN6! LIC=!HAS_LIC! ARCH=!DLL_ARCH! >> "!LOG_FILE!" 2>nul
set /a EXPECTED_TOTAL=2+HAS_INI+HAS_TN6+2*HAS_LIC
if "!HAS_DLL!"=="0" (
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    echo   [错误] 缺少必需文件 %DLL_NAME%，安装终止。
>> "!LOG_FILE!" 2>nul     echo   [错误] 缺少必需文件 %DLL_NAME%，安装终止。
    echo   请将 %DLL_NAME% 与本脚本放在同一目录后重试。
>> "!LOG_FILE!" 2>nul     echo   请将 %DLL_NAME% 与本脚本放在同一目录后重试。
    >> "!LOG_FILE!" 2>nul echo [ERROR] 必需文件 %DLL_NAME% 缺失, 不允许报告安装成功
    goto :exit_fail
)

REM === Step 1b: Determine target TDX architecture ===
if "!HAS_DLL!"=="1" (
    if "!DLL_ARCH!"=="32" goto :arch_ok
    if "!DLL_ARCH!"=="64" goto :arch_ok
)
echo.
>> "!LOG_FILE!" 2>nul echo.

echo   请选择通达信版本:
>> "!LOG_FILE!" 2>nul echo   请选择通达信版本:
echo   32 = 32位通达信, 64 = 64位通达信
>> "!LOG_FILE!" 2>nul echo   32 = 32位通达信, 64 = 64位通达信
set "ARCH_INPUT="
>> "!LOG_FILE!" 2>nul echo [SCREEN]  请输入 32 或 64: 
set /p "ARCH_INPUT=  请输入 32 或 64: "
>> "!LOG_FILE!" 2>nul echo [DIAG] ARCH_INPUT="!ARCH_INPUT!"
if "!ARCH_INPUT!"=="32" (set "DLL_ARCH=32" & goto :arch_ok)
if "!ARCH_INPUT!"=="64" (set "DLL_ARCH=64" & goto :arch_ok)
echo   输入无效
>> "!LOG_FILE!" 2>nul echo   输入无效
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
goto :exit_fail

:arch_ok
echo.
>> "!LOG_FILE!" 2>nul echo.
REM === Step 2: Find TDX installation directory ===
echo [步骤2] 查找 !DLL_ARCH! 位通达信安装目录
>> "!LOG_FILE!" 2>nul echo [步骤2] 查找 !DLL_ARCH! 位通达信安装目录
echo.
>> "!LOG_FILE!" 2>nul echo.
call :find_tdx_dir

if "!TDX_DIR!"=="" goto :tdx_not_found
echo.
>> "!LOG_FILE!" 2>nul echo.

REM === Step 3: Close TDX if running, then install files ===
echo [步骤3] 安装插件到通达信目录 [目标: !TDX_DIR!]
>> "!LOG_FILE!" 2>nul echo [步骤3] 安装插件到通达信目录 [目标: !TDX_DIR!]
echo.
>> "!LOG_FILE!" 2>nul echo.

set "RETRY=0"
:check_tdx_running
tasklist /fi "imagename eq !TDX_EXE!" 2>nul | find /i "!TDX_EXE!" >nul
if !ERRORLEVEL! NEQ 0 goto :tdx_closed
set /a RETRY+=1
if !RETRY! GTR 3 (
    echo   通达信未关闭, 安装终止
>> "!LOG_FILE!" 2>nul     echo   通达信未关闭, 安装终止
    echo   请先关闭通达信后再运行本脚本
>> "!LOG_FILE!" 2>nul     echo   请先关闭通达信后再运行本脚本
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    pause
goto :exit_fail
)
echo [LOG] TDX running, retry !RETRY!/3 >> "!LOG_FILE!" 2>nul
echo   通达信正在运行, 请关闭后按任意键重试 (!RETRY!/3)
>> "!LOG_FILE!" 2>nul echo   通达信正在运行, 请关闭后按任意键重试 ^(!RETRY!/3^)
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
>> "!LOG_FILE!" 2>nul     echo   创建 !TDX_DLLS_SUBDIR! 目录 ... [失败]
    echo   可能是 TDX 安装目录有写入保护, 请检查通达信安装目录权限
>> "!LOG_FILE!" 2>nul     echo   可能是 TDX 安装目录有写入保护, 请检查通达信安装目录权限
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    pause
goto :exit_fail
)
if not exist "!TDX_PLUGIN_DIR!" mkdir "!TDX_PLUGIN_DIR!" 2>nul
if not exist "!TDX_PLUGIN_DIR!" (
    echo [LOG] ERROR: mkdir failed: !TDX_PLUGIN_DIR! >> "!LOG_FILE!" 2>nul
    echo   创建 !TDX_PLUGIN_SUBDIR! 目录 ... [失败]
>> "!LOG_FILE!" 2>nul     echo   创建 !TDX_PLUGIN_SUBDIR! 目录 ... [失败]
    echo   可能是 TDX 安装目录有写入保护, 请检查通达信安装目录权限
>> "!LOG_FILE!" 2>nul     echo   可能是 TDX 安装目录有写入保护, 请检查通达信安装目录权限
    echo.
>> "!LOG_FILE!" 2>nul     echo.
    pause
goto :exit_fail
)

echo   -- 复制到 !TDX_DLLS_SUBDIR! --
>> "!LOG_FILE!" 2>nul echo   -- 复制到 !TDX_DLLS_SUBDIR! --
if "!HAS_DLL!"=="1" call :install_file "!DLL_FILE!" "!TDX_DLLS_DIR!\!DLL_NAME!"
if "!HAS_INI!"=="1" call :install_file "!INI_FILE!" "!TDX_DLLS_DIR!\!INI_NAME!"
if "!HAS_TN6!"=="1" call :install_file "!TN6_FILE!" "!TDX_DLLS_DIR!\!TN6_NAME!"
if "!HAS_LIC!"=="1" call :install_file "!LIC_FILE!" "!TDX_DLLS_DIR!\!LIC_NAME!"
echo.
>> "!LOG_FILE!" 2>nul echo.

echo   -- 复制到 !TDX_PLUGIN_SUBDIR! --
>> "!LOG_FILE!" 2>nul echo   -- 复制到 !TDX_PLUGIN_SUBDIR! --
if "!HAS_DLL!"=="1" call :install_file "!DLL_FILE!" "!TDX_PLUGIN_DIR!\!DLL_NAME!"
if "!HAS_LIC!"=="1" call :install_file "!LIC_FILE!" "!TDX_PLUGIN_DIR!\!LIC_NAME!"
echo.
>> "!LOG_FILE!" 2>nul echo.

echo [步骤4] 校验安装文件
>> "!LOG_FILE!" 2>nul echo [步骤4] 校验安装文件
echo.
>> "!LOG_FILE!" 2>nul echo.
echo   -- 校验 !TDX_DLLS_SUBDIR! --
>> "!LOG_FILE!" 2>nul echo   -- 校验 !TDX_DLLS_SUBDIR! --
if "!HAS_DLL!"=="1" call :verify_file "!DLL_FILE!" "!TDX_DLLS_DIR!\!DLL_NAME!"
if "!HAS_INI!"=="1" call :verify_file "!INI_FILE!" "!TDX_DLLS_DIR!\!INI_NAME!"
if "!HAS_TN6!"=="1" call :verify_file "!TN6_FILE!" "!TDX_DLLS_DIR!\!TN6_NAME!"
if "!HAS_LIC!"=="1" call :verify_file "!LIC_FILE!" "!TDX_DLLS_DIR!\!LIC_NAME!"
echo.
>> "!LOG_FILE!" 2>nul echo.
echo   -- 校验 !TDX_PLUGIN_SUBDIR! --
>> "!LOG_FILE!" 2>nul echo   -- 校验 !TDX_PLUGIN_SUBDIR! --
if "!HAS_DLL!"=="1" call :verify_file "!DLL_FILE!" "!TDX_PLUGIN_DIR!\!DLL_NAME!"
if "!HAS_LIC!"=="1" call :verify_file "!LIC_FILE!" "!TDX_PLUGIN_DIR!\!LIC_NAME!"
set "INSTALL_OK=1"
if not "!HAS_DLL!"=="1" set "INSTALL_OK=0"
if not "!COPY_FAIL!"=="0" set "INSTALL_OK=0"
if not "!VERIFY_FAIL!"=="0" set "INSTALL_OK=0"
if not "!COPY_TOTAL!"=="!EXPECTED_TOTAL!" set "INSTALL_OK=0"
if not "!VERIFY_TOTAL!"=="!EXPECTED_TOTAL!" set "INSTALL_OK=0"
call :log "Install summary: expected=!EXPECTED_TOTAL! copied=!COPY_TOTAL! copy_failed=!COPY_FAIL! verified=!VERIFY_TOTAL! verify_failed=!VERIFY_FAIL!"
echo.
>> "!LOG_FILE!" 2>nul echo.
if "!VERIFY_FAIL!"=="0" (
    echo   校验结果: 全部 !VERIFY_TOTAL! 个文件通过
>> "!LOG_FILE!" 2>nul     echo   校验结果: 全部 !VERIFY_TOTAL! 个文件通过
) else (
    echo   校验结果: 共 !VERIFY_TOTAL! 个文件, 其中 !VERIFY_FAIL! 个校验失败
>> "!LOG_FILE!" 2>nul     echo   校验结果: 共 !VERIFY_TOTAL! 个文件, 其中 !VERIFY_FAIL! 个校验失败
)
if not "!COPY_TOTAL!"=="!EXPECTED_TOTAL!" (
    echo   [错误] 复制项数 !COPY_TOTAL! 与预期 !EXPECTED_TOTAL! 不一致
>> "!LOG_FILE!" 2>nul     echo   [错误] 复制项数 !COPY_TOTAL! 与预期 !EXPECTED_TOTAL! 不一致
)
if not "!VERIFY_TOTAL!"=="!EXPECTED_TOTAL!" (
    echo   [错误] 校验项数 !VERIFY_TOTAL! 与预期 !EXPECTED_TOTAL! 不一致
>> "!LOG_FILE!" 2>nul     echo   [错误] 校验项数 !VERIFY_TOTAL! 与预期 !EXPECTED_TOTAL! 不一致
)
if "!INSTALL_OK!"=="1" goto :install_ok

echo   复制或校验未完整通过, 安装失败
>> "!LOG_FILE!" 2>nul echo   复制或校验未完整通过, 安装失败
echo   请参考用户手册手动完成安装
>> "!LOG_FILE!" 2>nul echo   请参考用户手册手动完成安装
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
goto :exit_fail

:install_ok
echo [LOG] Copy+verify finished: TDX_DIR=!TDX_DIR! arch=!DLL_ARCH! expected=!EXPECTED_TOTAL! copied=!COPY_TOTAL! verified=!VERIFY_TOTAL! failed=!VERIFY_FAIL! >> "!LOG_FILE!" 2>nul

:install_done
echo.
>> "!LOG_FILE!" 2>nul echo.
echo ============================================================
>> "!LOG_FILE!" 2>nul echo ============================================================
echo   安装结果: 成功，全部 !VERIFY_TOTAL! 个文件校验通过
>> "!LOG_FILE!" 2>nul echo   安装结果: 成功，全部 !VERIFY_TOTAL! 个文件校验通过
echo ============================================================
>> "!LOG_FILE!" 2>nul echo ============================================================
echo.
>> "!LOG_FILE!" 2>nul echo.
echo   通达信目录: !TDX_DIR! [!DLL_ARCH!位]
>> "!LOG_FILE!" 2>nul echo   通达信目录: !TDX_DIR! [!DLL_ARCH!位]
echo   - !TDX_DLLS_SUBDIR!\  (主图分析)
>> "!LOG_FILE!" 2>nul echo   - !TDX_DLLS_SUBDIR!\  ^(主图分析^)
echo   - !TDX_PLUGIN_SUBDIR!\      (插件选股)
>> "!LOG_FILE!" 2>nul echo   - !TDX_PLUGIN_SUBDIR!\      ^(插件选股^)
echo.
>> "!LOG_FILE!" 2>nul echo.
echo   使用方法:
>> "!LOG_FILE!" 2>nul echo   使用方法:
echo   1. 启动通达信
>> "!LOG_FILE!" 2>nul echo   1. 启动通达信
echo   2. 用 Ctrl+F 打开公式管理器
>> "!LOG_FILE!" 2>nul echo   2. 用 Ctrl+F 打开公式管理器
echo   3. 新装用户：在股票 K 线图里输入 ZEN [回车] 即可看到缠论分析结果
>> "!LOG_FILE!" 2>nul echo   3. 新装用户：在股票 K 线图里输入 ZEN [回车] 即可看到缠论分析结果
echo.
>> "!LOG_FILE!" 2>nul echo.
>> "!LOG_FILE!" 2>nul echo ============================================================
>> "!LOG_FILE!" 2>nul echo === 安装记录结束：段 1 与段 2 均已写入本文件 ===
>> "!LOG_FILE!" 2>nul echo ============================================================
REM 先把最后一段屏幕内容写进日志再发布; 发布成功后屏幕只显示、不再写日志,
REM 否则会在 %PUBLIC% 重建第二份残缺日志, 安装目录那份也会缺这几行。
set "FORMULA_HINT=[重要] 请在通达信中重新导入 !TN6_NAME! 并覆盖同名公式"
if "!HAS_TN6!"=="0" set "FORMULA_HINT=[提示] 未提供 !TN6_NAME!，跳过公式导入"
>> "!LOG_FILE!" 2>nul echo.
>> "!LOG_FILE!" 2>nul echo   ============================================================
>> "!LOG_FILE!" 2>nul echo   !FORMULA_HINT!
>> "!LOG_FILE!" 2>nul echo.
call :publish_log
echo.
echo   ============================================================
echo   !FORMULA_HINT!
echo.
REM 安装完成先回执以停止两分钟计时; 结果窗口退出时再回执, 才能释放运行锁。
if "!HAS_PARENT!"=="1" echo.> "!DONE_FLAG!" 2>nul
pause
REM EXIT_FLAG must be written BEFORE the self-delete below: (goto) aborts
REM the whole batch, so every line after it is dead and the parent window
REM would wait for a flag that never arrives.
if "!HAS_PARENT!"=="1" echo.> "!EXIT_FLAG!" 2>nul
REM Best-effort cleanup when running from the staged copy in %PUBLIC%
if /i not "!SCRIPT_DIR!"=="%PUBLIC%\zen_install_tmp" goto :skip_stage_clean
cd /d "!TEMP!" 2>nul
attrib -h "%PUBLIC%\zen_install_tmp" >nul 2>&1
(goto) 2>nul & rd /s /q "%PUBLIC%\zen_install_tmp" 2>nul
:skip_stage_clean
call :release_lock
exit /b 0

:tdx_not_found
echo [LOG] ERROR: TDX dir not found (arch=!DLL_ARCH!, all strategies exhausted) >> "!LOG_FILE!" 2>nul
echo.
>> "!LOG_FILE!" 2>nul echo.
echo [错误] 未找到 !DLL_ARCH! 位通达信安装目录
>> "!LOG_FILE!" 2>nul echo [错误] 未找到 !DLL_ARCH! 位通达信安装目录
echo.
>> "!LOG_FILE!" 2>nul echo.
echo 已尝试以下查找策略:
>> "!LOG_FILE!" 2>nul echo 已尝试以下查找策略:
echo   策略 1: 检查桌面快捷方式/任务栏/开始菜单
>> "!LOG_FILE!" 2>nul echo   策略 1: 检查桌面快捷方式/任务栏/开始菜单
echo   策略 2: 检查标准路径 (new_tdx / new_tdx64)
>> "!LOG_FILE!" 2>nul echo   策略 2: 检查标准路径 ^(new_tdx / new_tdx64^)
echo   策略 3: 全盘搜索 !TDX_EXE!
>> "!LOG_FILE!" 2>nul echo   策略 3: 全盘搜索 !TDX_EXE!
echo.
>> "!LOG_FILE!" 2>nul echo.
echo 可能的原因:
>> "!LOG_FILE!" 2>nul echo 可能的原因:
echo   - 通达信未安装
>> "!LOG_FILE!" 2>nul echo   - 通达信未安装
echo   - 当前安装包与已安装通达信版本位不匹配
>> "!LOG_FILE!" 2>nul echo   - 当前安装包与已安装通达信版本位不匹配
echo.
>> "!LOG_FILE!" 2>nul echo.
echo 请参考用户手册手动安装:
>> "!LOG_FILE!" 2>nul echo 请参考用户手册手动安装:
echo   1. 将所有文件复制到 !TDX_DLLS_SUBDIR!\ (主图分析): !DLL_NAME! / !INI_NAME! / !TN6_NAME! / !LIC_NAME!
>> "!LOG_FILE!" 2>nul echo   1. 将所有文件复制到 !TDX_DLLS_SUBDIR!\ ^(主图分析^): !DLL_NAME! / !INI_NAME! / !TN6_NAME! / !LIC_NAME!
echo   2. 将 !DLL_NAME! 与 !LIC_NAME! 同时复制到 !TDX_PLUGIN_SUBDIR!\
>> "!LOG_FILE!" 2>nul echo   2. 将 !DLL_NAME! 与 !LIC_NAME! 同时复制到 !TDX_PLUGIN_SUBDIR!\
echo       (与 T0002 平行的目录, 没有则手工新建)
>> "!LOG_FILE!" 2>nul echo       ^(与 T0002 平行的目录, 没有则手工新建^)
echo   3. 在通达信公式管理器中导入 !TN6_NAME!
>> "!LOG_FILE!" 2>nul echo   3. 在通达信公式管理器中导入 !TN6_NAME!
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
goto :exit_fail

:exit_fail
call :publish_log
if "!HAS_PARENT!"=="1" echo.> "!DONE_FLAG!" 2>nul
pause
if "!HAS_PARENT!"=="1" echo.> "!EXIT_FLAG!" 2>nul
call :release_lock
REM Drop the staged copy on failure too. Only the copy goes; the original
REM install dir is untouched. The two timeout exits deliberately keep it:
REM there the elevated instance may still be running out of it.
if "!IS_BOOTSTRAP!"=="1" goto :exit_fail_boot
if /i not "!SCRIPT_DIR!"=="%PUBLIC%\zen_install_tmp" goto :exit_fail_done
cd /d "!TEMP!" 2>nul
attrib -h "%PUBLIC%\zen_install_tmp" >nul 2>&1
(goto) 2>nul & rd /s /q "%PUBLIC%\zen_install_tmp" 2>nul
:exit_fail_done
exit /b 1
:exit_fail_boot
if defined STAGE_DIR attrib -h "!STAGE_DIR!" >nul 2>&1
if defined STAGE_DIR rd /s /q "!STAGE_DIR!" >nul 2>&1
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
REM Machine codes: 0x8664=x64, 0x014C=x86, 0xAA64=ARM64, 0x01C4=ARMNT.
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
>> "!_ARCH_PS1!" echo if ($m -eq 0x8664 -or $m -eq 0xAA64) { $r='64' } elseif ($m -eq 0x014C -or $m -eq 0x01C4) { $r='32' }
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
set /a COPY_TOTAL+=1
set "_COPY_OUT=%TEMP%\zen_copy_%RANDOM%.txt"
copy /Y "!_I_SRC!" "!_I_DST!" > "!_COPY_OUT!" 2>&1
set "_COPY_RC=!ERRORLEVEL!"
if exist "!_COPY_OUT!" type "!_COPY_OUT!" >> "!LOG_FILE!" 2>nul
del "!_COPY_OUT!" >nul 2>&1
if not "!_COPY_RC!"=="0" (
    set /a COPY_FAIL+=1
    call :log "COPY FAILED rc=!_COPY_RC!: !_I_SRC! => !_I_DST!"
    echo     !_FP! [复制失败]
>> "!LOG_FILE!" 2>nul     echo     !_FP! [复制失败]
    exit /b 0
)
call :log "COPY OK: !_I_DST!"
echo     !_FP! [完成]
>> "!LOG_FILE!" 2>nul echo     !_FP! [完成]
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
>> "!LOG_FILE!" 2>nul     echo     !_FP! [校验失败 目标缺失]
    set /a VERIFY_FAIL+=1
    exit /b 0
)
fc /b "!_I_SRC!" "!_I_DST!" >nul 2>&1
if errorlevel 1 (
    call :log "VERIFY FAILED (content mismatch): !_I_SRC! vs !_I_DST!"
    echo     !_FP! [校验失败]
>> "!LOG_FILE!" 2>nul     echo     !_FP! [校验失败]
    set /a VERIFY_FAIL+=1
) else (
    call :log "VERIFY OK: !_I_DST!"
    echo     !_FP! [通过]
>> "!LOG_FILE!" 2>nul     echo     !_FP! [通过]
)
exit /b 0

:fit_path
Rem %1=path %2=max display width. Sets _FP: exactly %2 console columns.
Rem Columns, not characters: under chcp 936 a CJK char is 2 GBK bytes and
Rem 2 columns, so the byte length of the echoed text IS its display width.
Rem Drive + first directory always shown in full (through the 2nd
Rem backslash, 4th for UNC); the rest is shortened with ... before the tail.
set "S=%~1"
set /a FPW=%~2
set "_WC_TMP=%TEMP%\zen_fit_%RANDOM%.txt"
set "_WC_S=!S!"
call :disp_w
if !_WC! LEQ !FPW! (
    set "_FP=!S!"
    goto :fit_pad
)
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
set "_WC_S=!S:~0,%HLEN%!"
call :disp_w
set /a TB=FPW-_WC-3
if !TB! LSS 1 goto :fit_head
set "_FP=!S:~0,%HLEN%!...!S:~-%TB%!"
:fit_tail
set "_WC_S=!_FP!"
call :disp_w
if !_WC! LEQ !FPW! goto :fit_pad
set /a TB=TB-_WC+FPW
if !TB! LSS 1 goto :fit_head
set "_FP=!S:~0,%HLEN%!...!S:~-%TB%!"
goto :fit_tail
:fit_head
set "_FP=!S:~0,%HLEN%!"
:fit_head_cut
set "_WC_S=!_FP!"
call :disp_w
if !_WC! LEQ !FPW! goto :fit_pad
set /a HLEN=HLEN-_WC+FPW
if !HLEN! LSS 1 (
    set "_FP="
    goto :fit_pad
)
set "_FP=!S:~0,%HLEN%!"
goto :fit_head_cut
:fit_pad
if not defined _FP (
    set "_FP=!PADSP:~0,%FPW%!"
    del "!_WC_TMP!" >nul 2>&1
    exit /b 0
)
set "_WC_S=!_FP!"
call :disp_w
set /a PADN=FPW-_WC
if !PADN! LSS 0 set /a PADN=0
set "_FP=!_FP!!PADSP:~0,%PADN%!"
del "!_WC_TMP!" >nul 2>&1
exit /b 0

:disp_w
Rem _WC_S = text. Sets _WC = console columns = GBK byte length minus CRLF.
> "!_WC_TMP!" echo !_WC_S!
for %%A in ("!_WC_TMP!") do set /a _WC=%%~zA-2
exit /b 0

:get_width
Rem Detect console width via [Console]::WindowWidth; fallback 80.
Rem PATH_W = width minus: 4-space indent, 1 space, longest status
Rem ([校验失败 目标缺失] = 19 columns) and 1 column of margin.
REM 终端宽度固定 80: 原用 PowerShell 读 [Console]::WindowWidth, 冷启动 2-4s 且仅影响长路径显示。
REM 固定 80 后 PATH_W=55 与实测一致, 不影响任何安装逻辑; 若需自适应可恢复上一行。
set "_CONW=80"
set /a PATH_W=_CONW-25
if !PATH_W! LSS 20 set "PATH_W=20"
call :log "Console width=!_CONW! PATH_W=!PATH_W!"
exit /b 0
:diag
REM 环境快照: 只在日志里, 不占屏幕; 用于定位 UAC / 代码页 / 权限 / 文件缺失类问题
>> "!LOG_FILE!" 2>nul echo [DIAG] === 环境快照 ===
>> "!LOG_FILE!" 2>nul echo [DIAG] ScriptDir   ="%~dp0"
>> "!LOG_FILE!" 2>nul echo [DIAG] User        ="%USERNAME%" domain="%USERDOMAIN%"
>> "!LOG_FILE!" 2>nul echo [DIAG] Session     ="%SESSIONNAME%"
>> "!LOG_FILE!" 2>nul echo [DIAG] Arch        ="%PROCESSOR_ARCHITECTURE%" / W6432="%PROCESSOR_ARCHITEW6432%"
>> "!LOG_FILE!" 2>nul echo [DIAG] SystemRoot  ="%SystemRoot%"
>> "!LOG_FILE!" 2>nul echo [DIAG] PUBLIC      ="%PUBLIC%"
>> "!LOG_FILE!" 2>nul echo [DIAG] TEMP        ="%TEMP%"
>> "!LOG_FILE!" 2>nul echo [DIAG] ProgramFiles="%ProgramFiles%"
chcp >> "!LOG_FILE!" 2>nul
net session >nul 2>&1
>> "!LOG_FILE!" 2>nul echo [DIAG] net_session_rc=!ERRORLEVEL! ^(0=已提权, 非0=未提权或 Server 服务停用^)
whoami /groups | findstr /i "S-1-5-32-544" >nul 2>&1
>> "!LOG_FILE!" 2>nul echo [DIAG] admin_group_rc=!ERRORLEVEL! ^(0=属于 Administrators^)
>> "!LOG_FILE!" 2>nul echo [DIAG] --- PowerShell / 执行策略 ---
powershell -NoProfile -Command "'PSVersion=' + $PSVersionTable.PSVersion.ToString(); Get-ExecutionPolicy -List | Out-String" >> "!LOG_FILE!" 2>&1
>> "!LOG_FILE!" 2>nul echo [DIAG] --- UAC 策略 ---
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA >> "!LOG_FILE!" 2>&1
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v ConsentPromptBehaviorAdmin >> "!LOG_FILE!" 2>&1
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v PromptOnSecureDesktop >> "!LOG_FILE!" 2>&1
>> "!LOG_FILE!" 2>nul echo [DIAG] --- 安装文件清点 ---
for %%F in (tdx_zen.dll dlls.ini tdx_zen.tn6 zen_license.key) do (
    if exist "%~dp0%%F" (
        for %%A in ("%~dp0%%F") do >> "!LOG_FILE!" 2>nul echo [DIAG]   %%F FOUND size=%%~zA
    ) else (
        >> "!LOG_FILE!" 2>nul echo [DIAG]   %%F MISSING
    )
)
>> "!LOG_FILE!" 2>nul echo [DIAG] === 快照结束 ===
exit /b 0

:publish_log
REM 有存活引导窗口时由它回写; 否则安装窗口自行保存, 不依赖可能残留的哨兵。
if not exist "!WORK_LOG!" exit /b 0
>> "!WORK_LOG!" 2>nul echo ============================================================
>> "!WORK_LOG!" 2>nul echo === 本次记录结束 ===
set "_PARENT_ALIVE=0"
if "!HAS_PARENT!"=="1" if exist "!PARENT_FLAG!" (
    for /f "usebackq delims=" %%P in ("!PARENT_FLAG!") do (
        call :pid_alive %%P
        if "!PID_ALIVE!"=="1" set "_PARENT_ALIVE=1"
    )
)
if "!HAS_PARENT!"=="1" if "!_PARENT_ALIVE!"=="1" (
    echo   安装日志: !LOG_DISPLAY!
>> "!LOG_FILE!" 2>nul     echo   安装日志: !LOG_DISPLAY!
    >> "!LOG_FILE!" 2>nul echo [LOG] 引导窗口会在本窗口退出后保存到 !LOG_TARGET! 并删除暂存副本
    exit /b 0
)
if "!HAS_PARENT!"=="1" (
    >> "!LOG_FILE!" 2>nul echo [LOG] 引导窗口已按单窗口流程退出, 由安装窗口保存日志
    del "!TIMEOUT_FLAG!" >nul 2>&1
)
if /i "!LOG_TARGET!"=="!WORK_LOG!" (
    echo   安装日志: !LOG_DISPLAY!
>> "!LOG_FILE!" 2>nul     echo   安装日志: !LOG_DISPLAY!
    exit /b 0
)
set "_PUB_OK=0"
set "_PUB_TGT="
call :try_publish "!LOG_TARGET!"
if "!_PUB_OK!"=="0" if not "!LOG_TARGET_UNC!"=="" call :try_publish "!LOG_TARGET_UNC!"
if "!_PUB_OK!"=="1" (
    echo   安装日志: !LOG_DISPLAY!
>> "!LOG_FILE!" 2>nul     echo   安装日志: !LOG_DISPLAY!
    copy /y "!WORK_LOG!" "!_PUB_TGT!" >nul 2>&1
    del "!WORK_LOG!" >nul 2>&1
    exit /b 0
)
echo   安装日志: !WORK_LOG!
>> "!LOG_FILE!" 2>nul echo   安装日志: !WORK_LOG!
>> "!WORK_LOG!" 2>nul echo [WARN] 日志未能保存到安装目录 !LOG_TARGET!。
>> "!WORK_LOG!" 2>nul echo [WARN] 原因: 目标目录不可见或不可写; 若使用映射盘, 请检查 UNC 备用路径与写权限。
>> "!WORK_LOG!" 2>nul echo [WARN] 本次完整记录保留在 !WORK_LOG!。
exit /b 1

:try_publish
REM 目标目录不可见时直接跳过, 不触发 cmd 的"系统找不到指定的路径"
for %%A in ("%~1") do set "_TGT_DIR=%%~dpA"
if not exist "!_TGT_DIR!" exit /b 0
copy /y "!WORK_LOG!" "%~1" >nul 2>&1
if not errorlevel 1 (
    set "_PUB_OK=1"
    set "_PUB_TGT=%~1"
)
exit /b 0

:parent_publish
REM 仅在安装窗口退出后调用, 此时工作日志已闭合且不会再有并发写入。
if not exist "!WORK_LOG!" exit /b 0
if /i "!LOG_TARGET!"=="!WORK_LOG!" exit /b 0
>> "!WORK_LOG!" 2>nul echo [LOG] 引导窗口回写日志: !WORK_LOG! -> !LOG_TARGET!
copy /y "!WORK_LOG!" "!LOG_TARGET!" >nul 2>&1
if errorlevel 1 (
    echo   安装日志: !WORK_LOG!
    >> "!WORK_LOG!" 2>nul echo [WARN] 回写失败, 日志保留在 !WORK_LOG!; 请手动复制到安装目录。
    exit /b 0
)
>> "!LOG_TARGET!" 2>nul echo [LOG] 日志已保存, 最终位置: !LOG_TARGET!
del "!WORK_LOG!" >nul 2>&1
if exist "!WORK_LOG!" (
    >> "!LOG_TARGET!" 2>nul echo [WARN] 暂存副本删除失败, 请手动删除 !WORK_LOG!
)
exit /b 0

:pid_alive
set "PID_ALIVE=0"
if "%~1"=="" exit /b 0
tasklist /FI "PID eq %~1" /NH 2>nul | findstr /i /c:"cmd.exe" | findstr /c:" %~1 " >nul 2>&1
if not errorlevel 1 set "PID_ALIVE=1"
exit /b 0

:lock_is_active
set "LOCK_ACTIVE=0"
if not exist "!LOCK_OWNER!" set "LOCK_ACTIVE=1"
if not exist "!LOCK_OWNER!" exit /b 0
for /f "usebackq delims=" %%P in ("!LOCK_OWNER!") do (
    call :pid_alive %%P
    if "!PID_ALIVE!"=="1" set "LOCK_ACTIVE=1"
)
exit /b 0

:release_lock
if not "!LOCK_HELD!"=="1" exit /b 0
del "!RUN_FLAG!" "!DONE_FLAG!" "!EXIT_FLAG!" "!PARENT_FLAG!" "!TIMEOUT_FLAG!" "!ELEV_FLAG!" >nul 2>&1
rd /s /q "!LOCK_DIR!" >nul 2>&1
set "LOCK_HELD=0"
exit /b 0

:log
REM %1 = single quoted English message. Redirect-first form avoids
REM the "trailing digit eats the redirect" cmd parsing bug.
>> "!LOG_FILE!" 2>nul echo [%DATE% %TIME%] %~1
exit /b 0

:check_tdx_candidate
REM Check candidate dir: has tdxw.exe with matching arch
set "_CAND_DIR=%~1"
REM %2 = 预探测架构(32/64), 由快捷方式扫描在同进程内顺便给出; 空/unknown 时回退单探测。
set "_PREARCH=%~2"
set "_CAND_FOUND=0"
if not exist "!_CAND_DIR!\!TDX_EXE!" exit /b 0
call :log "TDX candidate: !_CAND_DIR!"
REM 优先用预探测架构, 否则用缓存, 最后才回退 detect_arch(需启动 PS)。
if /i "!_PREARCH!"=="32" (
    set "_CAND_ARCH=32"
) else if /i "!_PREARCH!"=="64" (
    set "_CAND_ARCH=64"
) else if /i "!_CAND_DIR!"=="!_ARCH_SEEN_DIR!" (
    set "_CAND_ARCH=!_ARCH_SEEN_VAL!"
) else (
    set "_CAND_ARCH=unknown"
    call :detect_arch "!_CAND_DIR!\!TDX_EXE!" _CAND_ARCH
    set "_ARCH_SEEN_DIR=!_CAND_DIR!"
    set "_ARCH_SEEN_VAL=!_CAND_ARCH!"
)
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
set "_ARCH_SEEN_DIR="

REM -- 动态枚举真实盘符: 不硬编码 C..Z, 也不遗漏非常用盘符 --
REM ALL 含所有存在的盘(含网络映射盘), 用于策略 2 标准路径检查;
REM FIXED 仅本地固定盘(DriveType=3), 用于策略 3 递归搜索, 避免遍历网络盘过慢。
set "DRIVE_ALL="
set "DRIVE_FIXED="
set "_DRV_PS1=%TEMP%\zen_drives_%RANDOM%.ps1"
set "_DRV_OUT=%TEMP%\zen_drives_%RANDOM%.txt"
> "!_DRV_PS1!" echo param([string]$OutFile)
>> "!_DRV_PS1!" echo $all = New-Object System.Collections.Generic.List[string]
>> "!_DRV_PS1!" echo $fix = New-Object System.Collections.Generic.List[string]
>> "!_DRV_PS1!" echo try {
>> "!_DRV_PS1!" echo   foreach ($d in (Get-CimInstance Win32_LogicalDisk)) {
>> "!_DRV_PS1!" echo     $n = [string]$d.DeviceID
>> "!_DRV_PS1!" echo     if ($n.Length -ge 1) {
>> "!_DRV_PS1!" echo       $L = $n.Substring(0,1).ToUpper()
>> "!_DRV_PS1!" echo       $all.Add($L)
>> "!_DRV_PS1!" echo       if ($d.DriveType -eq 3) { $fix.Add($L) }
>> "!_DRV_PS1!" echo     }
>> "!_DRV_PS1!" echo   }
>> "!_DRV_PS1!" echo } catch {}
>> "!_DRV_PS1!" echo Set-Content -Path $OutFile -Value ('ALL=' + ($all.ToArray() -join ' '))
>> "!_DRV_PS1!" echo Add-Content -Path $OutFile -Value ('FIXED=' + ($fix.ToArray() -join ' '))
powershell -NoProfile -ExecutionPolicy Bypass -File "!_DRV_PS1!" "!_DRV_OUT!" >nul 2>&1
if exist "!_DRV_OUT!" for /f "usebackq tokens=1,* delims==" %%A in ("!_DRV_OUT!") do (
    if /i "%%A"=="ALL" set "DRIVE_ALL=%%B"
    if /i "%%A"=="FIXED" set "DRIVE_FIXED=%%B"
)
del "!_DRV_PS1!" >nul 2>&1
del "!_DRV_OUT!" >nul 2>&1
REM 枚举失败时退回静态盘符列表, 保证不会比原先更差。
if "!DRIVE_ALL!"=="" set "DRIVE_ALL=C D E F G H I J K L M N O P Q R S T U V W X Y Z"
if "!DRIVE_FIXED!"=="" set "DRIVE_FIXED=C D E F G H I J K"
echo [LOG] Drives ALL=[!DRIVE_ALL!] FIXED=[!DRIVE_FIXED!] >> "!LOG_FILE!" 2>nul
<nul set /p "=  策略 1: 检查桌面快捷方式/任务栏/开始菜单... "
>> "!LOG_FILE!" 2>nul echo [SCREEN]   策略 1: 检查桌面快捷方式/任务栏/开始菜单... 
call :find_tdx_from_shortcut
if not "!TDX_DIR!"=="" goto :find_done
echo [未找到]
>> "!LOG_FILE!" 2>nul echo [未找到]

<nul set /p "=  策略 2: 检查标准路径(new_tdx / new_tdx64)... "
>> "!LOG_FILE!" 2>nul echo [SCREEN]   策略 2: 检查标准路径^(new_tdx / new_tdx64^)... 
for %%D in (!DRIVE_ALL!) do (
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
>> "!LOG_FILE!" 2>nul echo.
<nul set /p "=  策略 3: 全盘搜索 !TDX_EXE!(请耐心等待, 可能较慢)... "
>> "!LOG_FILE!" 2>nul echo [SCREEN]   策略 3: 全盘搜索 !TDX_EXE!^(请耐心等待, 可能较慢^)... 
REM 全盘搜索只针对本地固定盘(DriveType=3): 映射网络盘若被 dir /s 整盘遍历会非常慢,
REM 网络盘上的通达信由策略 1 快捷方式和策略 2 标准路径覆盖。
for %%D in (!DRIVE_FIXED!) do (
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
>> "!LOG_FILE!" 2>nul echo [DIAG] find_tdx_dir result="!TDX_DIR!" arch="!DLL_ARCH!"
if not "!TDX_DIR!"=="" echo [找到 !DLL_ARCH! 位: !TDX_DIR!]
if not "!TDX_DIR!"=="" >> "!LOG_FILE!" 2>nul echo [找到 !DLL_ARCH! 位: !TDX_DIR!]
exit /b 0

:find_tdx_from_shortcut
REM 搜索范围: 当前用户/所有用户 桌面+开始菜单(两层), 当前用户任务栏固定项

REM -- Batch-resolve shortcuts via PowerShell script file --
REM (inline -Command is fragile through cmd quoting; -File avoids that)
set "SC_RESULT=%TEMP%\zen_sc_result_%RANDOM%.txt"
set "SC_PS1=%TEMP%\zen_sc_%RANDOM%.ps1"

> "!SC_PS1!" echo param([string]$Exe,[string]$OutFile,[string]$LogFile)
>> "!SC_PS1!" echo $shell = New-Object -ComObject WScript.Shell
>> "!SC_PS1!" echo try { Add-Type -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool GetBinaryType(string lpApplicationName, out uint lpBinaryType);' -Name ZenBin -Namespace Win32 } catch {}
>> "!SC_PS1!" echo $dirs = @("$env:USERPROFILE\Desktop","$env:PUBLIC\Desktop","$env:APPDATA\Microsoft\Windows\Start Menu","$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu","$env:APPDATA\Microsoft\Internet Explorer\Quick Launch")
>> "!SC_PS1!" echo $hits = New-Object System.Collections.Generic.List[string]
>> "!SC_PS1!" echo foreach ($d in $dirs) {
>> "!SC_PS1!" echo   if (-not (Test-Path -LiteralPath $d)) { Add-Content -Path $LogFile -Value "SC dir missing: $d"; continue }
>> "!SC_PS1!" echo   $files = @(Get-ChildItem -LiteralPath $d -Recurse -Filter *.lnk -Force -ErrorAction SilentlyContinue)
>> "!SC_PS1!" echo   Add-Content -Path $LogFile -Value ("SC dir {0} files={1}" -f $d, $files.Length)
>> "!SC_PS1!" echo   foreach ($f in $files) {
>> "!SC_PS1!" echo     try { $t = $shell.CreateShortcut($f.FullName).TargetPath } catch { $t = ''; Add-Content -Path $LogFile -Value "SC err: $($f.FullName)" }
>> "!SC_PS1!" echo     if ($t -and $t.ToLower().Contains($Exe)) {
>> "!SC_PS1!" echo       $dir = Split-Path -Parent $t
>> "!SC_PS1!" echo       $exe = Join-Path $dir $Exe
>> "!SC_PS1!" echo       if (-not (Test-Path -LiteralPath $exe)) { $exe = $t }
>> "!SC_PS1!" echo       $b = [uint32]0; $ar = 'unknown'
>> "!SC_PS1!" echo       try { if ([Win32.ZenBin]::GetBinaryType($exe, [ref]$b)) { if ($b -eq 0) { $ar = '32' } elseif ($b -eq 6) { $ar = '64' } } } catch {}
>> "!SC_PS1!" echo       $hits.Add($t + '^|' + $ar)
>> "!SC_PS1!" echo     }
>> "!SC_PS1!" echo   }
>> "!SC_PS1!" echo }
>> "!SC_PS1!" echo Add-Content -Path $LogFile -Value ("SC total hits=" + $hits.Count)
>> "!SC_PS1!" echo Set-Content -Path $OutFile -Value ($hits ^| Select-Object -Unique)

powershell -NoProfile -ExecutionPolicy Bypass -File "!SC_PS1!" "!TDX_EXE!" "!SC_RESULT!" "!LOG_FILE!" >nul 2>&1
echo [LOG] SC ps1 rc=!ERRORLEVEL! >> "!LOG_FILE!" 2>nul
type "!SC_RESULT!" >> "!LOG_FILE!" 2>nul
echo [LOG] SC result end >> "!LOG_FILE!" 2>nul
del "!SC_PS1!" >nul 2>&1

if not exist "!SC_RESULT!" exit /b 0
for /f "usebackq delims=" %%a in ("!SC_RESULT!") do (
    if "!TDX_DIR!"=="" (
        REM %%a 为 路径与架构的组合, 架构由 SC_PS1 在同进程内批量探测
        for /f "tokens=1,* delims=|" %%X in ("%%a") do (
            set "SHORTCUT_TARGET=%%X"
            set "PREARCH=%%Y"
        )
        for %%F in ("!SHORTCUT_TARGET!") do set "SHORTCUT_DIR=%%~dpF"
        if "!SHORTCUT_DIR:~-1!"=="\" set "SHORTCUT_DIR=!SHORTCUT_DIR:~0,-1!"
        if exist "!SHORTCUT_DIR!\!TDX_EXE!" (
            call :check_tdx_candidate "!SHORTCUT_DIR!" "!PREARCH!"
        )
    )
)
del "!SC_RESULT!" >nul 2>&1
exit /b 0

REM ============================================================
REM Safety net: if we reach here, main flow missed an exit point
REM ============================================================
echo.
>> "!LOG_FILE!" 2>nul echo.
echo [信息] 安装程序执行完毕
>> "!LOG_FILE!" 2>nul echo [信息] 安装程序执行完毕
echo.
>> "!LOG_FILE!" 2>nul echo.
pause
exit /b 0
