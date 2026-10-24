#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
ROOT='/Library/Application Support/SurgeDisconnectGuard'
LABEL='local.surgedisconnect.guard'
BOOT="/Library/LaunchDaemons/$LABEL.plist"
PREFERENCE=${2:-}
[[ $(id -u) == 0 ]] || exit 1
[[ "$PREFERENCE" == on || "$PREFERENCE" == off ]] || exit 2
apply_boot() {
    if [[ "$PREFERENCE" == on ]]; then
        install -o root -g wheel -m 644 "$ROOT/daemon.plist" "$BOOT"
        install -o root -g wheel -m 600 /dev/null "$ROOT/boot.enabled"
        launchctl enable "system/$LABEL"
    else
        rm -f "$BOOT" "$ROOT/boot.enabled"
    fi
}
case "${1:-}" in
    enable)
        if [[ -n "${3:-}" ]]; then "$ROOT/surge-guard" settings-set "$3"; fi
        "$ROOT/sgctl" enable
        apply_boot
        echo '已开启守护。'
        ;;
    disable)
        "$ROOT/sgctl" recover
        apply_boot
        "$ROOT/surge-guard" ui-state-write disabled '守护已关闭，已按备份恢复网络。'
        echo '已关闭守护并恢复网络。'
        ;;
    boot)
        apply_boot
        if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
            "$ROOT/surge-guard" ui-state-write disabled '守护当前已关闭，开机启动设置已更新。'
        fi
        echo '开机启动设置已更新。'
        ;;
    setTimeout)
        "$ROOT/surge-guard" settings-set "${3:-}"
        ;;
    diagnostics) "$ROOT/sgctl" status ;;
    uninstall)
        "$ROOT/sgctl" uninstall
        rm -f /var/run/local.surgedisconnect.guard.status.json /var/run/local.surgedisconnect.settings.json
        echo '后台组件已卸载。'
        ;;
    *) echo '操作不被允许。' >&2; exit 2 ;;
esac
