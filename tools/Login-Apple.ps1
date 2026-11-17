# 登录完全在用户自己的交互终端进行，不把密码写入命令行、日志或项目文件。
$ErrorActionPreference = 'Stop'
Write-Host 'Sign in to Apple locally. Enter your Apple ID, password and verification code when prompted.'
Write-Host 'Password input is hidden: type the password and press Enter. For a phone account, include the country code, without spaces.'
& wsl.exe -d Xtool-Ubuntu-24.04 -u mako -- bash -lc 'xtool auth login --mode password'
if ($LASTEXITCODE -ne 0) { throw 'Apple login did not complete. Please check the terminal message.' }

# 登录成功后只显示状态，不导出或复制任何账户凭据。
& wsl.exe -d Xtool-Ubuntu-24.04 -u mako -- bash -lc 'xtool auth status'
