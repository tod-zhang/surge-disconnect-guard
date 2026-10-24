# 使用与恢复

## 超时设置

在“设置 → 无响应超时”输入 10～10000 的整数毫秒值并保存，默认 200 ms。“恢复默认”会保存 200 ms。

数值越小越敏感，也更容易因调度或短暂卡顿误锁；数值越大，对无响应的容忍时间越长。保存不重启守护、不解锁网络，下一次开启或系统开机启动时读取保存值。界面分别显示当前使用值和下次开启值。

## 恢复网络

点击“关闭并恢复网络”。恢复无需联网，也不要求 Surge 运行。操作会先停止守护，再恢复备份中的网络服务、物理接口和 Wi-Fi 电源。VPN 可能需要手动重连；原来已关闭的服务不会被全部强行开启。

若应用窗口不可用，可在终端执行安装目录中的恢复入口：

```sh
sudo '/Library/Application Support/SurgeDisconnectGuard/sgctl' recover
```

这个备用入口会暂停守护的开机加载。以后需要保护时，在 Surge 双模式均开启后，通过应用重新开启。

恢复失败时，程序保留恢复备份并报告错误。不要删除 `locked.json` 或 `armed.json` 来代替恢复。

## 诊断与卸载

在“诊断”页面点击“读取诊断”。启动日志 `START 2.4.0` 包含本次实际使用的毫秒值。

在“设置”页面下方点击“卸载”，成功恢复后移除守护及权限组件。单独把应用拖到废纸篓不会停止已安装的后台。源码目录的新版“卸载并恢复网络.command”可作为管理员备用入口；从源码使用旧版安装脚本前需要先构建引擎。

## 系统文件

- 安装目录：`/Library/Application Support/SurgeDisconnectGuard/`
- 检测引擎任务：`/Library/LaunchDaemons/local.surgedisconnect.guard.plist`
- 权限组件任务：`/Library/LaunchDaemons/local.surgedisconnect.control.plist`
- 引擎日志：`/var/log/surge-disconnect-guard.log`
- 控制日志：`/var/log/surge-disconnect-control.log`
- 超时私有配置：安装目录中的 `settings.json`
- 界面只读配置副本：`/var/run/local.surgedisconnect.settings.json`

开机启动选项控制检测引擎；权限组件保留以接收控制操作，并不会因为自己启动而开启守护。登录后如需菜单栏图标，请打开应用。
