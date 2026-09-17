# diag_build_bat.ps1 -- 诊断 build.bat 报 'delayedexpansion' 错误的根因。
# 用法 (在 Z:\zen_plugin\applications 目录下):
#   powershell -NoProfile -ExecutionPolicy Bypass -File ..\install\diag_build_bat.ps1

$ErrorActionPreference = 'Continue'

$appsDir = (Resolve-Path '..\applications').Path
if (-not $appsDir) { $appsDir = (Get-Location).Path }

Write-Host "== diag_build_bat.ps1 =="
Write-Host "applications dir: $appsDir"
Write-Host ""

# 检查所有可能影响 build.bat 运行的 .bat / .cmd 文件的换行符
$batFiles = @(
    'build.bat',
    'android\build_android.bat',
    'android\zen_mobile\gradlew.bat',
    '..\src\build.bat',
    '..\src\build_aar.bat',
    '..\src\build_helper.bat'
)

function Test-File([string]$rel) {
    $abs = Join-Path $appsDir $rel
    if (-not (Test-Path -LiteralPath $abs)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($abs)
    $crlfCount = 0
    $lfOnlyCount = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A) {
            if ($i -gt 0 -and $bytes[$i - 1] -eq 0x0D) { $crlfCount++ }
            else { $lfOnlyCount++ }
        }
    }
    $total = $crlfCount + $lfOnlyCount
    if ($total -eq 0) { return }
    if ($lfOnlyCount -gt 0) {
        $pct = [int](($lfOnlyCount / $total) * 100)
        Write-Host "  [BROKEN] $rel -- $lfOnlyCount LF-only / $crlfCount CRLF ($pct% LF-only)"
    } else {
        Write-Host "  [OK]     $rel -- $crlfCount CRLF, 0 LF-only"
    }
}

Write-Host "Line-ending check:"
foreach ($f in $batFiles) { Test-File $f }
Write-Host ""

# 模拟 cmd.exe 解析第一行附近的逻辑：把前 10 行按 CRLF 切分看实际命令
$buildBat = Join-Path $appsDir 'build.bat'
if (Test-Path -LiteralPath $buildBat) {
    Write-Host "First 10 logical lines of build.bat (what cmd.exe sees):"
    $raw = [System.IO.File]::ReadAllText($buildBat)
    $lines = $raw -split "`r`n"
    for ($i = 0; $i -lt [Math]::Min(10, $lines.Length); $i++) {
        Write-Host ("  {0,3}: {1}" -f ($i + 1), $lines[$i])
    }
    Write-Host ""
    Write-Host "If line 4 is 'set MODE=%~1' instead of 'setlocal enabledelayedexpansion', the file is LF-only."
}
Write-Host ""
Write-Host "=== Diagnostic complete ==="
