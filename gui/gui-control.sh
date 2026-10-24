#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
SOURCE=$(cd -- "$(dirname -- "$0")/engine" && pwd -P)
ROOT='/Library/Application Support/SurgeDisconnectGuard'
LABEL='local.surgedisconnect.guard'
BOOT="/Library/LaunchDaemons/$LABEL.plist"
STATUS='/var/run/local.surgedisconnect.guard.status.json'
NEWSYSLOG_CONF='/etc/newsyslog.d/local.surgedisconnect.conf'
VERSION=$(tr -d '[:space:]' < "$SOURCE/VERSION")
ACTION=${1:-}
PREFERENCE=${2:-on}

[[ $(id -u) == 0 ]] || { echo '需要 macOS 管理员授权。' >&2; exit 1; }
[[ "$PREFERENCE" == on || "$PREFERENCE" == off ]] || { echo '开机启动参数无效。' >&2; exit 2; }

loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }
check_root() {
    if [[ -e "$ROOT" || -L "$ROOT" ]]; then
        [[ -d "$ROOT" && ! -L "$ROOT" && $(stat -f %u "$ROOT") == 0 ]] || {
            echo '安装目录所有者或类型异常，已停止操作。' >&2; exit 1;
        }
    fi
}
preflight() {
    "$SOURCE/surge-guard" health-check
    "$SOURCE/surge-guard" observer-check
    "$SOURCE/surge-guard" persistent-check
}
install_core() {
    check_root
    if [[ -f "$ROOT/engine-version" && $(cat "$ROOT/engine-version") == "$VERSION" ]]; then return; fi
    if loaded || [[ -f "$ROOT/locked.json" || -f "$ROOT/armed.json" ]]; then
        # Installing the permission helper must not fail because an older engine is still
        # guarding; that engine keeps running and is replaced after the next restore.
        if [[ "$ACTION" == prepare ]]; then echo '旧版守护仍在运行，将在下次关闭并恢复网络后升级。'; return; fi
        echo '检测到正在运行或已锁定的旧版。请先点击“关闭并恢复网络”，再开启新版。' >&2
        exit 1
    fi
    mkdir -p "$ROOT"
    chown root:wheel "$ROOT"
    chmod 700 "$ROOT"
    install -o root -g wheel -m 755 "$SOURCE/surge-guard" "$ROOT/surge-guard"
    install -o root -g wheel -m 755 "$SOURCE/sgctl" "$ROOT/sgctl"
    install -o root -g wheel -m 644 "$SOURCE/$LABEL.plist" "$ROOT/daemon.plist"
    install -o root -g wheel -m 644 "$SOURCE/local.surgedisconnect.newsyslog.conf" "$NEWSYSLOG_CONF"
    printf '%s\n' "$VERSION" > "$ROOT/engine-version"
    chmod 600 "$ROOT/engine-version"
}
apply_boot() {
    if [[ "$PREFERENCE" == on ]]; then
        install -o root -g wheel -m 644 "$ROOT/daemon.plist" "$BOOT"
        install -o root -g wheel -m 600 /dev/null "$ROOT/boot.enabled"
        # Enable loading at the next boot; this does not bootstrap a stopped job.
        launchctl enable "system/$LABEL"
    else
        # The current loaded job keeps its KeepAlive behavior. Removing the boot
        # plist only prevents the next boot from discovering it.
        rm -f "$BOOT" "$ROOT/boot.enabled"
    fi
}

check_root
case "$ACTION" in
    prepare)
        install_core
        echo '后台文件已准备；守护运行状态未更改。'
        ;;
    enable)
        preflight
        install_core
        "$ROOT/sgctl" enable
        apply_boot
        echo '已开启守护。后台将持续运行，关闭界面不会停止保护。'
        ;;
    disable)
        if [[ -x "$ROOT/sgctl" ]]; then "$ROOT/sgctl" recover; fi
        # Upgrade only after the old guard has stopped and its backup restored.
        install_core
        apply_boot
        "$ROOT/surge-guard" ui-state-write disabled '守护已关闭，已按备份恢复网络。'
        echo '已关闭守护并恢复网络。开机启动选项保持所选状态。'
        ;;
    boot)
        [[ -x "$ROOT/surge-guard" ]] || { echo '请先开启一次守护以安装后台组件。' >&2; exit 1; }
        if [[ ! -f "$ROOT/daemon.plist" ]]; then
            install -o root -g wheel -m 644 "$SOURCE/$LABEL.plist" "$ROOT/daemon.plist"
        fi
        apply_boot
        if ! loaded; then "$SOURCE/surge-guard" ui-state-write disabled '守护当前已关闭，开机启动设置已更新。'; fi
        echo '开机启动设置已更新。'
        ;;
    diagnostics)
        if [[ -x "$ROOT/sgctl" ]]; then "$ROOT/sgctl" status; else echo '后台组件尚未安装。'; fi
        ;;
    uninstall)
        if [[ -x "$ROOT/sgctl" ]]; then "$ROOT/sgctl" uninstall; fi
        rm -f "$BOOT" "$STATUS"
        echo '后台守护已卸载；应用本身可从“应用程序”移到废纸篓。'
        ;;
    *) echo '不支持的操作。' >&2; exit 2 ;;
esac
