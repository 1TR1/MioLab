#!/usr/bin/env bash
set -eo pipefail

# 系统登录脚本可能引用未设置的可选变量，加载完成后再开启严格变量检查。
source /etc/profile
set -u
task_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_project_dir"

# 设备桥接复用 Windows Apple Mobile Device 服务，仅连接本用户的 Unix socket。
export USBMUXD_SOCKET_ADDRESS="UNIX:$HOME/.cache/MioLibUSB/usbmuxd.sock"
if [[ ! -S "$HOME/.cache/MioLibUSB/usbmuxd.sock" ]]; then
  echo 'Device bridge is not running. Start tools/usbmux_bridge.py in WSL first.'
  exit 1
fi
xtool auth status
xtool devices --no-wait

# Release 构建签名并安装到当前 USB 设备；用户在设备上确认信任及开发者模式。
xtool dev run --configuration release --usb
