param([string]$CalibreDirectory = "$env:ProgramFiles\Calibre2")
$ErrorActionPreference = 'Stop'

# 只使用现有 Calibre 自带 Python，安装插件不需要额外的 Windows Python 环境。
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$calibreDebug = Join-Path $CalibreDirectory 'calibre-debug.exe'
$calibreCustomize = Join-Path $CalibreDirectory 'calibre-customize.exe'
if (-not (Test-Path -LiteralPath $calibreDebug)) { throw 'Calibre was not found. Specify -CalibreDirectory.' }
if (Get-Process calibre -ErrorAction SilentlyContinue) { throw 'Please close Calibre normally before installing the USB plugin.' }

# 先构建已知源码，再安装并幂等加入工具栏，不修改任何书籍或个人书库。
& $calibreDebug -e (Join-Path $PSScriptRoot 'build-calibre-plugin.py')
if ($LASTEXITCODE -ne 0) { throw 'Plugin packaging failed.' }
& $calibreCustomize -a (Join-Path $projectPath 'output\MioLib-Calibre-USB-1.0.0.zip')
if ($LASTEXITCODE -ne 0) { throw 'Plugin installation failed.' }
& $calibreDebug -e (Join-Path $PSScriptRoot 'configure-calibre-usb.py')
if ($LASTEXITCODE -ne 0) { throw 'Toolbar configuration failed.' }
Write-Host 'MioLib USB installed. Open Calibre and use the MioLib USB toolbar button.'
