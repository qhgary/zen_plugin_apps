# CRLF 紧急诊断（纯 cmd 内置命令，无需 PowerShell 脚本）

打开 cmd，进入 applications 目录，依次执行下面 5 条命令，把输出完整贴回来。

## 命令 1：检查 build.bat 前 6 行的实际字节

```
findstr /n "^" build.bat | findstr /b "1: 2: 3: 4: 5: 6:"
```

期望看到 6 行带行号内容。如果第 4 行是 `setlocal enabledelayedexpansion`，但报错指向它说明文件是 LF。

## 命令 2：用 debug 输出十六进制

```
cmd /u /c "type build.bat" > build_hex.txt
```

然后：

```
powershell -NoProfile -Command "$b=[IO.File]::ReadAllBytes('build_hex.txt'); Write-Host ('first 80 bytes: ' + ($b[0..79] | %% { '{0:X2}' -f $_ } | Join-String ' ')); Write-Host ('contains 0D 0A: ' + ($b -join ',' -match '13,10')); Write-Host ('contains bare 0A: ' + (for($i=0;$i -lt $b.Count;$i++){if($b[$i]-eq 10 -and ($i -eq 0 -or $b[$i-1] -ne 13)){$true;break}}))"
```

期望看到 `contains 0D 0A: True` 且 `contains bare 0A: False`。

## 命令 3：直接显示前 200 字节的 ASCII + 十六进制

```
powershell -NoProfile -Command "$bytes = [IO.File]::ReadAllBytes('build.bat'); $first = $bytes[0..199]; $hex = ($first | %% { '{0:X2}' -f $_ }) -join ' '; $txt = -join ($first | %% { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } }); Write-Host 'HEX:'; Write-Host $hex; Write-Host 'TXT:'; Write-Host $txt"
```

期望看到所有换行符都是 `0D 0A`（`..` 表示）。

## 命令 4：检查 build.bat 是否被强制 BOM/UTF-16 编码

```
powershell -NoProfile -Command "$b = [IO.File]::ReadAllBytes('build.bat')[0..3]; Write-Host ('First 4 bytes: ' + (($b | %% { '{0:X2}' -f $_ }) -join ' ')); if ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) { Write-Host 'UTF-16 LE BOM detected!' } elseif ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) { Write-Host 'UTF-8 BOM detected (OK)' } else { Write-Host 'No BOM (OK)' }"
```

## 命令 5：强制重建一个 CRLF 版本 build.bat 试试

```
powershell -NoProfile -Command "$src = 'build.bat'; $content = Get-Content -LiteralPath $src -Raw -Encoding UTF8; $norm = ($content -replace \"`r`n\", \"`n\") -replace \"`r\", \"`n\"; $norm = $norm -replace \"`n\", \"`r`n\"; [IO.File]::WriteAllText($src + '.new', $norm, (New-Object Text.UTF8Encoding $false)); Move-Item -Force ($src + '.new') $src; Write-Host 'build.bat regenerated as CRLF'"
```

然后再跑：

```
build.bat
```

---

## 如果命令 5 后还报错

请执行：

```
type build.bat | more
```

把第 1~6 行的输出贴回来。我能立即看出是 LF 还是别的字符问题。
