#!/bin/bash
set -u
DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
echo '即将安装系统级 Surge 断网守护，需要管理员密码。'
echo '请先打开 Surge，同时开启增强模式和系统代理。启用后，退出 Surge 或关闭任一模式都会断网。'
echo '开机时 Surge 尚未启动也会锁定断网。手动恢复入口在同一文件夹内。'
sudo /bin/bash "$DIR/install.sh"
RESULT=$?
[[ $RESULT == 0 ]] || echo "安装未完成（退出码 $RESULT），请查看上方信息。"
read -r -p '按回车关闭窗口…' _
exit "$RESULT"
