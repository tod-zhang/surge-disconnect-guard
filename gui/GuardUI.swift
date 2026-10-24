import SwiftUI
import AppKit
import Foundation
import Darwin
import Combine

let statusURL = URL(fileURLWithPath: "/var/run/local.surgedisconnect.guard.status.json")
let installPath = "/Library/Application Support/SurgeDisconnectGuard"

struct GuardStatus: Decodable {
    var installed: Bool
    var phase: String
    var message: String
    var boot: Bool
    var updatedAt: Double
    var daemonPID: Int32
    var version: String
    var timeoutMS: Int?
    var isFresh: Bool { abs(Date().timeIntervalSince1970 - updatedAt) < 5 }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}
func authorizationScript(script: String, pid: Int32) -> String {
    let command = ["/bin/bash", script, String(pid)].map(shellQuote).joined(separator: " ")
    return "do shell script " + appleQuote(command) + " with administrator privileges"
}

final class GuardModel: ObservableObject {
    @Published var installed = false
    @Published var phase = "uninstalled"
    @Published var detail = "首次安装权限组件需管理员授权；此版本后续日常开关无需重复输入密码。"
    @Published var boot = true
    @Published var busy = false
    @Published var pendingAction: String?
    @Published var activity = ""
    @Published var output = ""
    @Published var showDetails = false
    @Published var timeoutMS = GuardSettings.defaultTimeoutMS
    @Published var timeoutText = String(GuardSettings.defaultTimeoutMS)
    @Published var activeTimeoutMS: Int?
    @Published var engineOutdated = false
    let preview: Bool
    private var timer: Timer?
    init() {
        preview = CommandLine.arguments.contains("--preview")
        boot = UserDefaults.standard.object(forKey: "bootPreference") as? Bool ?? true
        let savedMS = UserDefaults.standard.object(forKey: "timeoutPreferenceMS") as? Int ?? GuardSettings.defaultTimeoutMS
        timeoutMS = (try? GuardSettings(timeoutMS: savedMS))?.timeoutMS ?? GuardSettings.defaultTimeoutMS
        timeoutText = String(timeoutMS)
        if preview { detail = "这是界面预览。所有按钮只模拟状态，不安装组件，也不修改网络。" }
        else { refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, !self.preview, !self.busy else { return }
            self.refresh()
        }
    }
    var title: String {
        switch phase {
        case "protecting": return "正在守护"
        case "locked": return "网络已锁定"
        case "starting": return "正在确认保护状态"
        case "unknown", "error": return "保护状态待确认"
        case "disabled": return "守护已关闭"
        default: return "尚未开启守护"
        }
    }
    var color: Color {
        switch phase {
        case "protecting": return Color(red: 0.36, green: 0.89, blue: 0.68)
        case "locked": return Color(red: 1, green: 0.58, blue: 0.36)
        case "starting", "unknown", "error": return .yellow
        default: return Color.white.opacity(0.65)
        }
    }
    var primaryAction: String { installed && phase != "disabled" ? "disable" : "enable" }
    var primaryTitle: String {
        if busy && pendingAction == "enable" { return "正在开启…" }
        if busy && pendingAction == "disable" { return "正在关闭并恢复网络…" }
        return primaryAction == "enable" ? "开启守护" : "关闭并恢复网络"
    }
    func refresh() {
        installed = FileManager.default.fileExists(atPath: installPath)
        if installed, FileManager.default.fileExists(atPath: GuardSettings.publicPath), let saved = try? GuardSettings.load(from: GuardSettings.publicPath) {
            adoptTimeout(saved.timeoutMS)
        }
        activeTimeoutMS = nil
        if let data = try? Data(contentsOf: statusURL), let status = try? JSONDecoder().decode(GuardStatus.self, from: data), installed {
            engineOutdated = status.version != "2.3.0"
            activeTimeoutMS = status.timeoutMS
            boot = status.boot
            UserDefaults.standard.set(boot, forKey: "bootPreference")
            let livePhase = ["protecting", "starting", "locked"].contains(status.phase)
            if livePhase && !status.isFresh {
                phase = "unknown"
                detail = "后台状态已超过 5 秒未更新。可查看诊断，或关闭守护并恢复网络。"
            } else {
                phase = status.phase; detail = status.message
            }
        } else if installed {
            engineOutdated = true
            phase = "unknown"
            detail = "检测到后台组件，尚未获得当前状态。旧版升级前请先关闭并恢复网络。"
        } else {
            engineOutdated = false
            phase = "uninstalled"
            detail = "首次安装权限组件需管理员授权；此版本后续日常开关无需重复输入密码。"
        }
    }
    var parsedTimeout: Int? { try? GuardSettings.parse(timeoutText) }
    var timeoutInputError: String? {
        do { _ = try GuardSettings.parse(timeoutText); return nil }
        catch { return String(describing: error) }
    }
    var timeoutCaption: String {
        if let active = activeTimeoutMS, ["protecting", "starting", "locked"].contains(phase) {
            return active == timeoutMS ? "当前使用 \(active) ms。修改后下次开启守护生效。" : "当前使用 \(active) ms；下次开启将使用 \(timeoutMS) ms。"
        }
        return "已保存 \(timeoutMS) ms，下次开启守护生效。"
    }
    private func adoptTimeout(_ value: Int) {
        let unchanged = timeoutText == String(timeoutMS)
        timeoutMS = value
        UserDefaults.standard.set(value, forKey: "timeoutPreferenceMS")
        if unchanged { timeoutText = String(value) }
    }
    func saveTimeout() {
        guard !busy, let value = parsedTimeout else { return }
        if preview || !installed {
            adoptTimeout(value)
            timeoutText = String(value)
            activity = preview ? "预览：超时已保存，下次开启生效。" : "超时已保存，将在首次开启守护时应用。"
        } else { perform("setTimeout", timeoutOverride: value) }
    }
    func resetTimeout() {
        guard !busy else { return }
        timeoutText = String(GuardSettings.defaultTimeoutMS)
        saveTimeout()
    }
    func setBoot(_ value: Bool) {
        guard !busy else { return }
        let old = boot
        boot = value
        UserDefaults.standard.set(value, forKey: "bootPreference")
        if installed { perform("boot", rollbackBoot: old) }
    }
    func perform(_ action: String, rollbackBoot: Bool? = nil, timeoutOverride: Int? = nil) {
        guard !busy else { return }
        if preview {
            switch action {
            case "enable": installed = true; phase = "protecting"; activeTimeoutMS = timeoutMS; detail = "预览：增强模式与系统代理均已开启，后台正在守护。"
            case "disable": phase = "disabled"; activeTimeoutMS = nil; detail = "预览：已停止守护并恢复网络。开机启动设置保持不变。"
            case "uninstall": installed = false; phase = "uninstalled"; detail = "预览：后台组件已卸载。"
            default: break
            }
            activity = "预览操作完成，实际系统与网络未改动。"
            return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        let installer = resources.appendingPathComponent("install-control.sh").path
        let script = authorizationScript(script: installer, pid: getpid())
        let selectedBoot = boot
        let selectedTimeoutMS = action == "enable" ? timeoutMS : timeoutOverride
        pendingAction = action
        busy = true
        activity = "正在处理…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = "", success = false
            do {
                var probe = try? requestControl(ControlRequest(.ping))
                // Allow launchd to restart an existing helper before asking to repair it.
                if probe == nil && FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/" + controlLabel + ".plist") {
                    for _ in 0..<25 {
                        usleep(200_000)
                        probe = try? requestControl(ControlRequest(.ping))
                        if probe != nil { break }
                    }
                }
                if probe?.success != true || probe?.version != controlVersion {
                    DispatchQueue.main.async { [weak self] in self?.activity = "首次安装或更新权限组件，等待管理员授权…" }
                    let task = Process(), pipe = Pipe()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    task.arguments = ["-e", script]
                    task.standardOutput = pipe; task.standardError = pipe
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    result = String(decoding: data, as: UTF8.self)
                    guard task.terminationStatus == 0 else { throw ControlFailure(result) }
                    var ready = false
                    for _ in 0..<50 {
                        if let reply = try? requestControl(ControlRequest(.ping)), reply.success, reply.version == controlVersion {
                            ready = true; break
                        }
                        usleep(100_000)
                    }
                    guard ready else { throw ControlFailure("权限组件尚未就绪，请查看诊断或稍后重试。") }
                }
                guard let command = ControlAction(rawValue: action), command != .prepareUpgrade, command != .ping else {
                    throw ControlFailure("操作不被允许。")
                }
                let reply = try requestControl(ControlRequest(command, boot: selectedBoot, timeoutMS: selectedTimeoutMS))
                result += reply.output
                success = reply.success
            } catch { result = String(describing: error) }
            let capturedResult = result, capturedSuccess = success
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.busy = false
                self.pendingAction = nil
                self.output = capturedResult
                if !capturedSuccess, let old = rollbackBoot {
                    self.boot = old; UserDefaults.standard.set(old, forKey: "bootPreference")
                }
                if capturedSuccess && action == "setTimeout", let value = selectedTimeoutMS {
                    self.adoptTimeout(value)
                    self.timeoutText = String(value)
                }
                self.refresh()
                if capturedSuccess {
                    self.activity = action == "diagnostics" ? "诊断信息已读取。" : action == "setTimeout" ? "超时已保存，下次开启守护生效。" : "操作完成。"
                } else {
                    self.activity = capturedResult.contains("-128") ? "已取消管理员授权。" : "操作未完成，请查看详细信息。"
                    self.showDetails = true
                }
                if action == "diagnostics" { self.showDetails = true }
            }
        }
    }
}

private enum GuardPage: String, CaseIterable {
    case overview = "守护", settings = "设置", diagnostics = "诊断"
}

private enum GuardPalette {
    static let mint = Color(red: 0.40, green: 0.87, blue: 0.69)
    static let blue = Color(red: 0.48, green: 0.70, blue: 0.95)
    static let gold = Color(red: 0.86, green: 0.75, blue: 0.48)
    static let secondary = Color.white.opacity(0.56)
    static let subtle = Color.white.opacity(0.34)
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct GlassPanel: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.055)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    }
}
private struct SoftButton: ButtonStyle {
    var prominent = false
    var tint: Color = GuardPalette.mint
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 19).frame(height: 40)
            .foregroundStyle(prominent ? Color(red: 0.08, green: 0.17, blue: 0.14) : Color.white.opacity(0.86))
            .background(RoundedRectangle(cornerRadius: 12).fill(prominent ? tint : .white.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(prominent ? 0.20 : 0.09), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.80 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GuardView: View {
    @StateObject private var model: GuardModel
    @State private var page: GuardPage = .overview
    @State private var confirmUninstall = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: GuardModel = GuardModel()) { _model = StateObject(wrappedValue: model) }

    private var accent: Color {
        ["disabled", "uninstalled"].contains(model.phase) ? GuardPalette.mint : model.color
    }
    private var summary: String {
        switch model.phase {
        case "protecting": return "双模式已确认开启。Surge 退出或状态异常时，\n自动锁定本机网络。"
        case "disabled": return "网络已按备份恢复。\n准备好后，可随时重新开启守护。"
        case "locked": return "已触发断网保护。\n查看诊断，或关闭守护并恢复网络。"
        case "starting": return "正在确认增强模式与系统代理。\n请稍候，状态会自动更新。"
        case "unknown", "error": return "暂时无法确认后台状态。\n查看诊断，或关闭守护并恢复网络。"
        default: return "在 Surge 异常时自动锁网。\n开启前，请同时打开增强模式与系统代理。"
        }
    }
    var body: some View {
        ZStack {
            WindowMaterial().ignoresSafeArea()
            LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.16).opacity(0.86),
                                    Color(red: 0.09, green: 0.105, blue: 0.12).opacity(0.94)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.075), .clear], center: .topTrailing,
                           startRadius: 10, endRadius: 560).ignoresSafeArea()
            VStack(spacing: 0) {
                navigation.frame(height: 86)
                Group {
                    switch page {
                    case .overview: overview
                    case .settings: settings
                    case .diagnostics: diagnostics
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 28).padding(.bottom, 20)
                footer
            }
        }
        .foregroundStyle(.white)
        .frame(width: 860, height: 640)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showDetails) { details }
    }

    private var navigation: some View {
        HStack {
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(GuardPalette.mint)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.07), in: Circle())
                    .padding(.trailing, 7)
                    .accessibilityLabel("Surge 断网守护")
                ForEach(GuardPage.allCases, id: \.self) { item in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { page = item }
                    } label: {
                        Text(item.rawValue).font(.system(size: 13, weight: .semibold))
                            .frame(width: 76, height: 36)
                            .foregroundStyle(page == item ? Color.black.opacity(0.88) : Color.white.opacity(0.55))
                            .background {
                                if page == item { Capsule().fill(.white.opacity(0.96)).shadow(color: .black.opacity(0.16), radius: 5, y: 2) }
                            }
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("tab-" + item.rawValue)
                        .accessibilityAddTraits(page == item ? [.isSelected] : [])
                }
            }.padding(6).background(.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
            Spacer()
        }.padding(.top, 5)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("保护概览").font(.system(size: 21, weight: .semibold))
                    Text("本机网络的保护状态。").font(.system(size: 12)).foregroundStyle(GuardPalette.secondary)
                }
                Spacer()
                Label(model.preview ? "安全预览" : "本机守护", systemImage: model.preview ? "eye" : "desktopcomputer")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(GuardPalette.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.05), in: Capsule())
            }.padding(.bottom, 3)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Circle().fill(model.color).frame(width: 6, height: 6)
                        Text("网络保护").font(.system(size: 11, weight: .semibold)).tracking(1)
                            .foregroundStyle(GuardPalette.secondary)
                        if model.busy { ProgressView().controlSize(.mini).tint(accent) }
                    }.padding(.bottom, 14)
                    Text(model.title).font(.system(size: 34, weight: .semibold)).tracking(-0.8)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(summary).font(.system(size: 13)).foregroundStyle(GuardPalette.secondary)
                        .lineSpacing(5).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 18)
                    Button { model.perform(model.primaryAction) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: model.primaryAction == "enable" ? "power" : "network")
                            Text(model.primaryTitle)
                            Spacer(minLength: 3)
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        }.frame(width: 194)
                    }.buttonStyle(SoftButton(prominent: model.primaryAction == "enable", tint: accent))
                        .disabled(model.busy).opacity(model.busy ? 0.5 : 1)
                        .accessibilityIdentifier(model.primaryAction == "enable" ? "enableGuard" : "disableGuard")
                }.frame(maxWidth: .infinity, alignment: .leading)
                shieldArtwork.frame(width: 258)
            }.padding(27).frame(height: 264).modifier(GlassPanel())
            HStack(spacing: 14) {
                modeCard("增强模式", icon: "square.3.layers.3d", tint: GuardPalette.mint)
                modeCard("系统代理", icon: "network", tint: GuardPalette.blue)
                Button { page = .settings } label: {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Label("开机守护", systemImage: "sunrise").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(GuardPalette.gold)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium)).foregroundStyle(GuardPalette.subtle)
                        }
                        Text(model.boot ? "已开启" : "未开启").font(.system(size: 22, weight: .semibold))
                        Text(model.boot ? "系统启动时自动布防" : "由你手动开启保护")
                            .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(19).modifier(GlassPanel(radius: 17))
                }.buttonStyle(.plain).accessibilityIdentifier("openBootSettings")
            }
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").foregroundStyle(GuardPalette.subtle)
                Text("异常后保持网络锁定，需手动关闭守护并恢复。")
                    .foregroundStyle(GuardPalette.secondary)
                Spacer()
                Button("了解设置") { page = .settings }.buttonStyle(.plain).foregroundStyle(GuardPalette.mint)
            }.font(.system(size: 11)).padding(.horizontal, 3).padding(.top, 3)
        }
    }

    private var shieldArtwork: some View {
        let tint = ["disabled", "uninstalled"].contains(model.phase) ? Color(red: 0.57, green: 0.65, blue: 0.66) : accent
        let symbol = model.phase == "protecting" ? "checkmark.shield.fill" : model.phase == "locked" ? "lock.shield.fill" : "shield.lefthalf.filled"
        return ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.18), tint.opacity(0.035), .clear], center: .center, startRadius: 25, endRadius: 116))
                .frame(width: 232, height: 232)
            Circle().stroke(tint.opacity(0.06), lineWidth: 1).frame(width: 206, height: 206)
            Circle().stroke(tint.opacity(0.13), lineWidth: 1).frame(width: 165, height: 165)
            RoundedRectangle(cornerRadius: 33)
                .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 33).strokeBorder(.white.opacity(0.13), lineWidth: 1))
                .frame(width: 124, height: 132).rotationEffect(.degrees(-9))
                .shadow(color: tint.opacity(0.10), radius: 24, y: 8)
            Image(systemName: symbol).font(.system(size: 71, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.98), tint.opacity(0.58)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: tint.opacity(0.18), radius: 14, y: 4)
            Image(systemName: model.phase == "protecting" ? "checkmark" : model.phase == "locked" ? "lock.fill" : "power")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                .frame(width: 33, height: 33).background(Color(red: 0.15, green: 0.21, blue: 0.21), in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.30), lineWidth: 1))
                .offset(x: 60, y: 57)
        }.accessibilityHidden(true)
    }

    private func modeCard(_ title: String, icon: String, tint: Color) -> some View {
        let confirmed = model.phase == "protecting"
        return VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            HStack(spacing: 8) {
                Text(confirmed ? "已开启" : "待确认").font(.system(size: 22, weight: .semibold))
                if confirmed { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(tint) }
            }
            Text(confirmed ? "Surge 已确认" : (["disabled", "uninstalled"].contains(model.phase) ? "开启守护后持续检查" : "当前状态无法确认"))
                .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(19).modifier(GlassPanel(radius: 17))
    }

    private var settings: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            pageHeading("守护设置", subtitle: "按你的习惯，安排每一次连接。")
            timeoutEditor
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    settingIcon("sunrise", tint: GuardPalette.gold)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开机自动启动守护").font(.system(size: 14, weight: .semibold))
                        Text("后台随系统启动，无需打开窗口。").font(.system(size: 12)).foregroundStyle(GuardPalette.secondary)
                    }
                    Spacer()
                    Toggle("开机自动启动守护", isOn: Binding(get: { model.boot }, set: { model.setBoot($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(GuardPalette.mint)
                        .disabled(model.busy).accessibilityIdentifier("startAtBoot")
                }
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(GuardPalette.gold).padding(.top, 1)
                    Text("开机时 Surge 未就绪也会锁网。关闭守护后若保留此选项，下次开机会重新布防。")
                        .foregroundStyle(GuardPalette.secondary).lineSpacing(4)
                }.font(.system(size: 12))
            }.padding(22).modifier(GlassPanel(radius: 18))
            HStack(alignment: .top, spacing: 14) {
                settingIcon("key.horizontal", tint: GuardPalette.mint)
                VStack(alignment: .leading, spacing: 7) {
                    Text("一次授权，日常免密码").font(.system(size: 14, weight: .semibold))
                    Text("本版本首次操作需管理员授权，重启后仍然有效。\n更新界面签名、重装或修复权限组件时，可能需要重新授权。")
                        .font(.system(size: 12)).foregroundStyle(GuardPalette.secondary).lineSpacing(4)
                }
                Spacer()
            }.padding(22).modifier(GlassPanel(radius: 18))
            Spacer(minLength: 0)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("卸载后台组件").font(.system(size: 12, weight: .medium))
                    Text("先恢复网络，再移除守护和权限组件。").font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
                }
                Spacer()
                Button("卸载…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(SoftButton()).disabled(model.busy || !model.installed)
                    .opacity(!model.installed ? 0.4 : 1).accessibilityIdentifier("uninstallGuard")
                    .confirmationDialog("确定卸载后台组件？", isPresented: $confirmUninstall) {
                        Button("恢复网络并卸载", role: .destructive) { model.perform("uninstall") }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将先停止守护并按备份恢复网络，再移除守护和权限组件。")
                    }
            }.padding(.top, 6)
        }
            }
    }

    private var timeoutEditor: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                settingIcon("waveform.path", tint: GuardPalette.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("无响应超时").font(.system(size: 14, weight: .semibold))
                    Text("默认 200 ms · 输入 10～10000 的整数")
                        .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    TextField("200", text: $model.timeoutText)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .onSubmit { model.saveTimeout() }
                        .accessibilityIdentifier("timeoutInput")
                    Text("ms").font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
                }.padding(.horizontal, 12).frame(width: 108, height: 40)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .disabled(model.busy)
                Button("保存") { model.saveTimeout() }.buttonStyle(SoftButton(prominent: true))
                    .disabled(model.busy || model.parsedTimeout == nil || model.parsedTimeout == model.timeoutMS)
                    .opacity(model.busy || model.parsedTimeout == nil || model.parsedTimeout == model.timeoutMS ? 0.45 : 1)
                    .accessibilityIdentifier("saveTimeout")
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = model.timeoutInputError {
                        Text(error).foregroundStyle(Color.orange)
                    } else {
                        Text(model.timeoutCaption).foregroundStyle(GuardPalette.secondary)
                    }
                    Text("数值越小越敏感，越大越能容忍卡顿。明确的模式关闭或退出事件不等待此超时。")
                        .foregroundStyle(GuardPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).lineSpacing(3)
                Spacer(minLength: 12)
                Button("恢复默认") { model.resetTimeout() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(GuardPalette.mint).disabled(model.busy)
                    .accessibilityIdentifier("resetTimeout")
            }
            if model.engineOutdated {
                Text("旧版后台尚待升级，请先用旧版关闭并恢复网络。")
                    .font(.system(size: 11)).foregroundStyle(GuardPalette.gold)
            }
        }.padding(22).modifier(GlassPanel(radius: 18))
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                pageHeading("运行诊断", subtitle: "查看后台状态，找到每一次锁网的原因。")
                Spacer()
                Button { model.perform("diagnostics") } label: { Label("读取诊断", systemImage: "arrow.clockwise") }
                    .buttonStyle(SoftButton()).disabled(model.busy).accessibilityIdentifier("readDiagnostics")
            }
            HStack(spacing: 10) {
                Circle().fill(model.color).frame(width: 7, height: 7)
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("状态约每秒刷新").font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
            }.padding(18).modifier(GlassPanel(radius: 14))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("最近操作输出", systemImage: "terminal").font(.system(size: 11, weight: .medium))
                    Spacer()
                    if !model.output.isEmpty {
                        Button("展开") { model.showDetails = true }.buttonStyle(.plain).foregroundStyle(GuardPalette.mint).font(.system(size: 11))
                    }
                }.foregroundStyle(GuardPalette.secondary).padding(17)
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                if model.output.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 31, weight: .light)).foregroundStyle(GuardPalette.subtle)
                        Text("还没有诊断记录").font(.system(size: 14, weight: .medium))
                        Text("点击“读取诊断”，获取当前状态和最近日志。")
                            .font(.system(size: 12)).foregroundStyle(GuardPalette.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(.white.opacity(0.76)).frame(maxWidth: .infinity, alignment: .leading).padding(17)
                    }
                }
            }.frame(maxHeight: .infinity).modifier(GlassPanel(radius: 18))
            Label("读取状态不会主动触发断网。", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary).padding(.horizontal, 3)
        }
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 21, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(GuardPalette.secondary)
        }.padding(.bottom, 3)
    }
    private func settingIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .regular)).foregroundStyle(tint)
            .frame(width: 42, height: 42).background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.mini).tint(GuardPalette.mint) }
            else { Image(systemName: "menubar.rectangle").foregroundStyle(GuardPalette.subtle) }
            Text(model.activity.isEmpty ? "关闭窗口后，可从菜单栏打开。" : model.activity)
                .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary).lineLimit(1)
            if !model.output.isEmpty {
                Button("查看详情") { model.showDetails = true }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(GuardPalette.mint)
            }
            Spacer(minLength: 12)
            Text(model.preview ? "安全预览" : "Surge 断网守护 · 2.3.0")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(GuardPalette.subtle)
        }.padding(.horizontal, 28).frame(height: 43)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.065)).frame(height: 1) }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("操作详情", systemImage: "terminal").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("完成") { model.showDetails = false }.keyboardShortcut(.defaultAction)
                    .buttonStyle(SoftButton())
            }
            ScrollView {
                Text(model.output.isEmpty ? model.activity : model.output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(.white.opacity(0.80)).frame(maxWidth: .infinity, alignment: .leading).padding(17)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        }.padding(24).frame(width: 710, height: 450)
            .background(Color(red: 0.10, green: 0.13, blue: 0.15)).preferredColorScheme(.dark)
    }
}

enum GuardIndicator: CaseIterable {
    case protecting, locked, attention, inactive
    init(phase: String) {
        switch phase {
        case "protecting": self = .protecting
        case "locked": self = .locked
        case "starting", "unknown", "error": self = .attention
        default: self = .inactive
        }
    }
    var color: NSColor {
        switch self {
        case .protecting: return NSColor(red: 0.20, green: 0.82, blue: 0.56, alpha: 1)
        case .locked: return .systemOrange
        case .attention: return .systemYellow
        case .inactive: return NSColor.black.withAlphaComponent(0.52)
        }
    }
    func image() -> NSImage {
        let tint = color
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            tint.setStroke()
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 10, y: 18))
            shield.line(to: NSPoint(x: 17, y: 15))
            shield.line(to: NSPoint(x: 16, y: 8))
            shield.curve(to: NSPoint(x: 10, y: 2), controlPoint1: NSPoint(x: 15, y: 5), controlPoint2: NSPoint(x: 12, y: 3))
            shield.curve(to: NSPoint(x: 4, y: 8), controlPoint1: NSPoint(x: 8, y: 3), controlPoint2: NSPoint(x: 5, y: 5))
            shield.line(to: NSPoint(x: 3, y: 15))
            shield.close()
            shield.lineWidth = 1.7
            shield.lineJoinStyle = .round
            shield.stroke()
            let power = NSBezierPath()
            power.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 3, startAngle: 135, endAngle: 45, clockwise: false)
            power.move(to: NSPoint(x: 10, y: 14))
            power.line(to: NSPoint(x: 10, y: 10.5))
            power.lineWidth = 1.6
            power.lineCapStyle = .round
            power.stroke()
            return true
        }
        // Template rendering follows light/dark menu bars while staying dimmed.
        image.isTemplate = self == .inactive
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = GuardModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleGuard), keyEquivalent: "")
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = NSHostingView(rootView: GuardView(model: model))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Surge 断网守护"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        configureMenuBar()
        configureApplicationMenu()
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateMenuBar() }
        }.store(in: &subscriptions)
        showWindow()
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "显示主窗口", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        toggleItem.target = self
        menu.addItem(toggleItem)
        let diagnostics = NSMenuItem(title: "查看诊断…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        diagnostics.tag = 1
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出界面（守护继续运行）", action: #selector(quitInterface), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateMenuBar()
    }

    private func configureApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "退出 Surge 断网守护界面", action: #selector(quitInterface), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func updateMenuBar() {
        let title = "Surge 断网守护：" + model.title
        statusItem?.button?.image = GuardIndicator(phase: model.phase).image()
        statusItem?.button?.toolTip = title
        statusItem?.button?.setAccessibilityLabel(title)
        stateItem.title = model.title
        toggleItem.title = model.primaryTitle
        toggleItem.isEnabled = !model.busy
        statusItem?.menu?.item(withTag: 1)?.isEnabled = !model.busy
    }

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleGuard() { model.perform(model.primaryAction) }
    @objc private func showDiagnostics() {
        showWindow()
        model.perform("diagnostics")
    }
    @objc private func quitInterface() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
}

func uiSelfTest() -> Bool {
    let value = "a'b $(printf EXPANDED) `printf CMD` \"quoted\" \\ tail"
    let quoted = shellQuote(value)
    guard quoted.contains("'\\''"), quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return false }
    let script = authorizationScript(script: "/A B/C'd/install-control.sh", pid: 12345)
    guard script.contains("with administrator privileges"), script.contains("'12345'") else { return false }
    let test = Process(), pipe = Pipe()
    test.executableURL = URL(fileURLWithPath: "/bin/sh")
    test.arguments = ["-c", "printf %s " + quoted]
    test.standardOutput = pipe
    do { try test.run(); test.waitUntilExit() } catch { return false }
    guard String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == value else { return false }
    var error: NSDictionary?
    guard NSAppleScript(source: script)?.compileAndReturnError(&error) == true else { return false }
    let data = Data("{\"installed\":true,\"phase\":\"locked\",\"message\":\"测试\",\"boot\":true,\"updatedAt\":0,\"daemonPID\":5,\"version\":\"2.0\"}".utf8)
    guard let status = try? JSONDecoder().decode(GuardStatus.self, from: data), status.phase == "locked", !status.isFresh else { return false }
    guard GuardIndicator(phase: "protecting") == .protecting,
          GuardIndicator(phase: "disabled") == .inactive,
          GuardIndicator(phase: "uninstalled") == .inactive,
          GuardIndicator(phase: "locked") == .locked,
          GuardIndicator(phase: "unknown") == .attention else { return false }
    for indicator in GuardIndicator.allCases {
        let image = indicator.image()
        guard image.size == NSSize(width: 20, height: 20),
              image.isTemplate == (indicator == .inactive), image.tiffRepresentation != nil else { return false }
    }
    return true
}

@main enum SurgeGuardApp {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let success = uiSelfTest()
            print(success ? "PASS GUI 状态解析、菜单栏图标状态及管理员命令引用检查。未修改系统。" : "FAIL GUI 自检")
            exit(success ? 0 : 1)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
