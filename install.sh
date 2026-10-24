#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
SOURCE=$(cd -- "$(dirname -- "$0")" && pwd -P)
ROOT='/Library/Application Support/SurgeDisconnectGuard'
LABEL='local.surgedisconnect.guard'
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[[ $(id -u) == 0 ]] || { echo '请通过“安装并启用.command”运行。' >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || { echo '这个预编译版本适用于 Apple Silicon。请用随附源码在目标 Mac 上编译。' >&2; exit 1; }
[[ -x /Applications/Surge.app/Contents/MacOS/Surge ]] || { echo '未找到 /Applications/Surge.app。' >&2; exit 1; }

if [[ -e "$ROOT" || -L "$ROOT" || -e "$PLIST" || -L "$PLIST" ]]; then
    echo '检测到已有安装或残留文件。请先使用已有工具恢复/卸载，保留断网备份后再安装。' >&2
    exit 1
fi

plutil -lint "$SOURCE/$LABEL.plist"
"$SOURCE/surge-guard" self-test
"$SOURCE/surge-guard" health-check
"$SOURCE/surge-guard" observer-check
"$SOURCE/surge-guard" persistent-check
mkdir -m 700 "$ROOT"
chown root:wheel "$ROOT"
install -o root -g wheel -m 755 "$SOURCE/surge-guard" "$ROOT/surge-guard"
install -o root -g wheel -m 755 "$SOURCE/sgctl" "$ROOT/sgctl"
install -o root -g wheel -m 644 "$SOURCE/$LABEL.plist" "$PLIST"
install -o root -g wheel -m 644 "$SOURCE/$LABEL.plist" "$ROOT/daemon.plist"
# Explicit enable also clears a paused state left by a previous uninstall.
"$ROOT/sgctl" enable
echo '安装完成。Surge 退出、增强模式或系统代理关闭/状态未知都会触发断网。'
