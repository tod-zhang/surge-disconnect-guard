#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
ROOT='/Library/Application Support/SurgeDisconnectGuard'
LABEL='local.surgedisconnect.guard'
BOOT="/Library/LaunchDaemons/$LABEL.plist"
STATUS=/var/run/local.surgedisconnect.guard.status.json
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
        if [[ -n "${4:-}" ]]; then "$ROOT/surge-guard" settings-interval "$4"; fi
        if [[ -n "${5:-}" ]]; then "$ROOT/surge-guard" settings-auto-restore "$5"; fi
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
    setInterval)
        "$ROOT/surge-guard" settings-interval "${3:-}"
        ;;
    setAutoRestore)
        # Read by the running guard within a second; nothing is restarted.
        "$ROOT/surge-guard" settings-auto-restore "${3:-}"
        ;;
    diagnostics) "$ROOT/sgctl" status ;;
    idle)
        # Run by the helper at its own start. /var/run is emptied at boot, so without
        # this a stopped guard would leave the UI with no status at all after reboot.
        if [[ ! -f "$STATUS" ]] && ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
            if [[ -f "$ROOT/locked.json" || -f "$ROOT/armed.json" ]]; then
                "$ROOT/surge-guard" ui-state-write error '守护未运行，但仍保留断网备份。请点击“关闭并恢复网络”按备份恢复后再开启。'
            else
                "$ROOT/surge-guard" ui-state-write disabled '守护当前已关闭。'
            fi
        fi
        ;;
    uninstall)
        "$ROOT/sgctl" uninstall --keep-control
        rm -f /var/run/local.surgedisconnect.guard.status.json /var/run/local.surgedisconnect.settings.json
        echo '后台组件已卸载。'
        ;;
    *) echo '操作不被允许。' >&2; exit 2 ;;
esac
