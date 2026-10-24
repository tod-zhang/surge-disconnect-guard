#!/bin/bash
set -u
echo '请先打开 Surge，同时开启增强模式和系统代理。此操作会重新启用守护及开机启动。'
sudo '/Library/Application Support/SurgeDisconnectGuard/sgctl' enable
RESULT=$?
[[ $RESULT == 0 ]] || echo "未能启用（退出码 $RESULT），请查看上方信息。"
read -r -p '按回车关闭窗口…' _
exit "$RESULT"
