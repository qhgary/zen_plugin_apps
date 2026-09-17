# fix_bat_crlf.ps1 -- 把 applications 目录下的所有 .bat 文件转回 CRLF 格式。
# 用途: 当 build.bat 报 "'delayedexpansion' is not recognized as an internal or external command"
# 或其他诡异语法错误时,通常是 .bat 被保存为 LF 换行所致。
# 用法: 在 PowerShell 中执行  powershell -NoProfile -ExecutionPolicy Bypass -File fix_bat_crlf.ps1

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$targets = @(
    (Join-Path $scriptRoot '..\build.bat'),
    (Join-Path $scriptRoot '..\android\build_android.bat')
)

function Test-Crlf([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    # 查找第一个换行符: 若为 LF (0x0A) 直接出现而前面没有 CR (0x0D), 则不是 CRLF
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A) {
            return ($i -gt 0 -and $bytes[$i - 1] -eq 0x0D)
        }
    }
    return $true
}

function ConvertTo-Crlf([string]$path) {
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    # 规范化: \r\n -> \n -> \r\n
    $normalized = ($content -replace "`r`n", "`n") -replace "`r", "`n"
    $normalized = $normalized -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($path, $normalized, (New-Object System.Text.UTF8Encoding($false)))
}

foreach ($rel in $targets) {
    $abs = [System.IO.Path]::GetFullPath($rel)
    if (-not (Test-Path -LiteralPath $abs)) {
        Write-Host "[skip] $abs (not found)"
        continue
    }
    $ok = Test-Crlf $abs
    if ($ok) {
        Write-Host "[ok]   $abs (already CRLF)"
    } else {
        ConvertTo-Crlf $abs
        Write-Host "[fix]  $abs (converted to CRLF)"
    }
}

Write-Host ""
Write-Host "Done. Re-run build.bat from applications directory."
