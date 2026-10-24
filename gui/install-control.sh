#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
SOURCE=$(cd -- "$(dirname -- "$0")" && pwd -P)
ROOT='/Library/Application Support/SurgeDisconnectGuard'
LABEL='local.surgedisconnect.control'
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CLIENT_PID=${1:-}
[[ $(id -u) == 0 && "$CLIENT_PID" =~ ^[1-9][0-9]*$ ]] || { echo '需要管理员授权及有效的界面进程。' >&2; exit 1; }
# Prepare fixed engine files without enabling/disabling the guard or changing boot preference.
/bin/bash "$SOURCE/gui-control.sh" prepare off
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    # Ask the running helper to exit only when no privileged operation is in progress.
    if [[ -x "$ROOT/sg-control" ]]; then "$ROOT/sg-control" stop; fi
    launchctl bootout "system/$LABEL"
fi
install -o root -g wheel -m 755 "$SOURCE/engine/sg-control" "$ROOT/sg-control"
install -o root -g wheel -m 755 "$SOURCE/control-actions.sh" "$ROOT/control-actions.sh"
"$ROOT/sg-control" authorize "$CLIENT_PID"
install -o root -g wheel -m 644 "$SOURCE/$LABEL.plist" "$PLIST"
launchctl enable "system/$LABEL"
launchctl bootstrap system "$PLIST"
echo '权限组件已安装。此版本后续日常操作无需再次输入密码。'
