#!/bin/bash
set -u
echo '即将停止并卸载守护，同时按备份恢复网络。'
sudo /bin/bash -c '
ROOT="/Library/Application Support/SurgeDisconnectGuard"
# Fall back to the engine controller when the permission helper is not running.
if [[ -x "$ROOT/sg-control" ]] && "$ROOT/sg-control" uninstall; then
    exit 0
fi
"$ROOT/sgctl" uninstall
'
RESULT=$?
[[ $RESULT == 0 ]] || echo "卸载未完成（退出码 $RESULT）。恢复失败时，程序和备份会保留。"
read -r -p '按回车关闭窗口…' _
exit "$RESULT"
