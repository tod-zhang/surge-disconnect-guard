# Surge 断网守护

macOS 上的 Surge 网络保护工具。当 Surge 退出、被监控组件退出、增强模式或系统代理关闭，以及运行状态无法确认时，触发本机网络锁定，并提供手动恢复入口。

[下载 v2.3.0 DMG](https://github.com/tod-zhang/surge-disconnect-guard/releases/tag/v2.3.0) · [使用说明](docs/usage.md) · [验证范围](docs/validation.md)

![界面示例，运行于安全预览模式](docs/preview.png)

## 功能

- 原生深空风格界面，包含守护、设置和诊断三个页面（⌘1～⌘3 切换）；守护状态以一颗持续自转的二次元风格带环星球呈现：守护中为薄荷绿，锁网为珊瑚橙，待确认为金色，关闭为灰蓝色。主按钮随当前状态切换。
- 关闭窗口后保留菜单栏图标：守护中为绿色，关闭为暗色，锁网为橙色，状态待确认为黄色。
- 可选系统开机启动守护；界面无需保持打开。
- 一次管理员授权安装本版本权限组件，之后同版开启、关闭、保存设置及查看诊断无需重复输入密码。
- 无响应超时默认 **200 ms**，支持输入 **10～10000 ms** 的整数、保存及恢复默认。
- 保存的超时在**下次开启守护时生效**，当前守护继续使用原值；配置重启后保留。
- 异常后持续保持锁网，Surge 重新运行不会自动解除锁定。手动关闭守护时按备份恢复网络状态。

本工具会主动断开网络，包括局域网连接。它是用户态响应工具，**不能保证零数据包泄漏或几毫秒内完成真实断网**。模式判断依赖 Surge 报告的状态，并不探测每条连接或代理节点的实际可用性。

## 安装与使用

适用于 **Apple Silicon、macOS 13+**；开发验证环境为 macOS 26.3。需要 Surge 安装在 `/Applications/Surge.app`。提供的应用使用本地 ad-hoc 签名，未经过 Apple Developer ID 签名或公证。

1. 从 Releases 下载 DMG，将应用拖到 Applications。
2. 打开 Surge，同时开启增强模式和系统代理。
3. 打开本应用，点击“开启守护”，首次完成管理员授权。
4. 等待状态显示“正在守护”。需要恢复时点击“关闭并恢复网络”。

“设置 → 无响应超时”可自定义毫秒数。明确返回模式关闭或收到进程退出事件时，不会等待该超时；首次连接最多等待 500 ms，查询之间间隔约 5 ms。

开机启动**没有宽限期**：Surge 尚未就绪也会锁网。关闭守护后若保留开机启动选项，下次开机会重新开启。关闭窗口会收起到菜单栏；选择“退出界面”才会移除图标，已开启的后台守护仍继续运行。

### 从旧版升级到 2.3.0

先在旧版点击“关闭并恢复网络”，退出旧界面，再替换应用并重新开启。该版本更新后台引擎和权限组件，首次控制操作需重新授权一次，之后同版继续免密。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools。测试脚本需要 Python 3，无第三方 Python 依赖。

```sh
# 仅编译检测引擎并运行自检
./build.sh

# 运行隔离控制流程测试，不执行真实特权操作
python3 test_controller.py
python3 gui/test_gui_control.py
python3 gui/test_permission_control.py

# 构建原生应用和 DMG；构建过程中会运行引擎、GUI 和权限组件自检
mkdir -p dist
./gui/build-dmg.sh "$PWD/.build/release" "$PWD/dist/SurgeDisconnectGuard-2.3.0.dmg"
```

构建和自检不安装后台、不改变网络。真实安装、开关守护和恢复网络请通过应用完成。

## 实现结构

| 文件 | 用途 |
| --- | --- |
| `SurgeGuard.swift` | 进程退出监听、持续模式查询、锁网、恢复及内存模拟自检 |
| `native.c` | 原生网卡控制、进程信息、受控子进程及退出事件接口 |
| `GuardSettings.swift` | 超时范围校验、配置持久化及共享自检 |
| `gui/GuardUI.swift` | SwiftUI / AppKit 界面、菜单栏及控制客户端 |
| `gui/ControlService.swift` | root 权限组件，核验用户身份、审计令牌及固定代码签名 |
| `gui/ControlIPC.swift` | 私有本地控制协议，仅接受预设动作与经过校验的参数 |
| `gui/control-actions.sh` | root 目录中的固定控制操作 |
| `gui/build-dmg.sh` | 编译、自检、签名及 DMG 打包 |

不保存管理员密码，不修改 sudoers，不记录网络流量。更换界面签名的新版、换用户、重装或修复组件时，可能需要再次授权。
