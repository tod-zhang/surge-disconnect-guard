#!/bin/bash
set -u
echo '此操作会暂停守护，并按断网前的备份恢复网络。Surge 无需正在运行。'
sudo '/Library/Application Support/SurgeDisconnectGuard/sgctl' recover
RESULT=$?
[[ $RESULT == 0 ]] || echo "恢复失败（退出码 $RESULT），备份会保留。请查看使用说明。"
read -r -p '按回车关闭窗口…' _
exit "$RESULT"
