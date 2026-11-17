param([string]$Distribution = 'Xtool-Ubuntu-24.04')
$ErrorActionPreference = 'Stop'

# 在既有环境中定位项目，密码与设备配对均由 xtool / iOS 系统处理。
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$linuxPath = (& wsl.exe -d $Distribution -- wslpath -u $projectPath).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot map the project path into WSL.' }
Write-Host 'Keep the iPhone unlocked. Accept Trust / Developer Mode prompts on the device.'

# 桥接已由开发会话或 Start-DeviceBridge.ps1 启动，安装期间不改变 Windows USB 驱动。
$linuxScript = "$linuxPath/tools/install-device.sh"
& wsl.exe -d $Distribution -u mako -- bash $linuxScript
if ($LASTEXITCODE -ne 0) { throw 'Device installation did not complete. See the xtool message.' }
