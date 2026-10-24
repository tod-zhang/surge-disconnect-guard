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
    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .settings: return "2"
        case .diagnostics: return "3"
        }
    }
    var kicker: String {
        switch self {
        case .overview: return "GUARD"
        case .settings: return "SETTINGS"
        case .diagnostics: return "DIAGNOSTICS"
        }
    }
}

/// Street-comic palette: ink black, acid yellow-green, hot pink and cyan accents.
private enum Zine {
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let acid = rgb(0xD4FF2A)
    static let hot = rgb(0xFF3D7F)
    static let cyan = rgb(0x27E3FF)
    static let amber = rgb(0xFFB020)
    static let ink = rgb(0x0A0A0C)
    static let bg = rgb(0x111114)
    static let panel = rgb(0x1B1B20)
    static let edge = rgb(0x34343C)
    static let footer = rgb(0x0C0C0E)
    static let secondary = Color.white.opacity(0.66)
    static let subtle = Color.white.opacity(0.40)
}

/// A parallelogram leaning right, used for tabs, tags and buttons.
private struct Slant: Shape {
    var lean: CGFloat = 0.26
    func path(in rect: CGRect) -> Path {
        let dx = rect.height * lean
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + dx, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - dx, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Sticker look: flat fill, inked edge and a hard offset shadow.
private struct Sticker: ViewModifier {
    var fill: Color
    var shadow: Color = Zine.ink
    var border: Color = Zine.ink
    var depth: CGFloat = 3
    func body(content: Content) -> some View {
        content
            .background(Slant().fill(fill))
            .overlay(Slant().stroke(border, lineWidth: 2))
            .background(Slant().fill(shadow).offset(x: depth, y: depth))
    }
}

/// Comic panel for settings and diagnostics: flat panel, coloured spine and a hard shadow.
private struct ComicPanel: ViewModifier {
    var spine: Color = Zine.acid
    func body(content: Content) -> some View {
        content
            .background(Rectangle().fill(Zine.panel))
            .overlay(alignment: .leading) { Rectangle().fill(spine).frame(width: 4) }
            .overlay(Rectangle().stroke(Zine.edge, lineWidth: 1.5))
            .background(Rectangle().fill(Color.black).offset(x: 5, y: 5))
    }
}

/// Slanted sticker button: the face lifts on hover and sinks into its shadow when pressed.
private struct SlantButton: ButtonStyle {
    var fill: Color = Zine.acid
    var text: Color = Zine.ink
    var shadow: Color = Zine.hot
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        SlantBody(configuration: configuration, fill: fill, text: text, shadow: shadow, large: large)
    }
    private struct SlantBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        let text: Color
        let shadow: Color
        let large: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let pressed = configuration.isPressed
            let shift: CGFloat = pressed ? 3 : (hovering && isEnabled ? -1.5 : 0)
            configuration.label
                .font(.system(size: large ? 16 : 13, weight: .heavy))
                .foregroundColor(text)
                .padding(.horizontal, large ? 36 : 22).frame(height: large ? 46 : 36)
                .background(Slant().fill(fill))
                .overlay(Slant().stroke(Zine.ink, lineWidth: large ? 3 : 2.5))
                .offset(x: shift, y: shift)
                .background(Slant().fill(shadow).offset(x: large ? 6 : 4, y: large ? 6 : 4))
                .contentShape(Slant())
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: pressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Plain text button that brightens on hover.
private struct HoverLink: ButtonStyle {
    var tint: Color = Zine.acid
    func makeBody(configuration: Configuration) -> some View {
        HoverLinkBody(configuration: configuration, tint: tint)
    }
    private struct HoverLinkBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(tint.opacity(configuration.isPressed ? 0.6 : hovering ? 1 : 0.85))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Diamond status marker with an inked edge.
private struct Diamond: View {
    var color: Color
    var size: CGFloat = 9
    var body: some View {
        Rectangle().fill(color)
            .overlay(Rectangle().stroke(Zine.ink, lineWidth: 1.5))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .accessibilityHidden(true)
    }
}

/// Dark backdrop with a diagonal slash, halftone corners in the state colour, and CRT scanlines.
private struct StreetBackdrop: View {
    var tint: Color
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Zine.bg))
            var slash = Path()
            slash.move(to: CGPoint(x: 0, y: size.height * 0.64))
            slash.addLine(to: CGPoint(x: size.width, y: size.height * 0.30))
            slash.addLine(to: CGPoint(x: size.width, y: size.height * 0.47))
            slash.addLine(to: CGPoint(x: 0, y: size.height * 0.81))
            slash.closeSubpath()
            context.fill(slash, with: .color(Color.white.opacity(0.028)))
            StreetBackdrop.halftone(in: &context, center: CGPoint(x: size.width * 0.88, y: size.height * 0.10), radius: 300, color: tint)
            StreetBackdrop.halftone(in: &context, center: CGPoint(x: size.width * 0.06, y: size.height * 0.94), radius: 250, color: Zine.hot)
            var lines = Path()
            var y: CGFloat = 0
            while y < size.height {
                lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            context.fill(lines, with: .color(Color.white.opacity(0.03)))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private static func halftone(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let step: CGFloat = 9
        var dots = Path()
        var y = center.y - radius
        var row = 0
        while y < center.y + radius {
            var x = center.x - radius + (row % 2 == 0 ? 0 : step / 2)
            while x < center.x + radius {
                let distance = hypot(x - center.x, y - center.y)
                if distance < radius {
                    let r = 1.9 * (1 - distance / radius)
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
                x += step
            }
            y += step
            row += 1
        }
        context.fill(dots, with: .color(color.opacity(0.22)))
    }
}

/// Caution-tape strip.
private struct CautionTape: View {
    var color: Color = Zine.acid
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Zine.ink))
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripes.addLine(to: CGPoint(x: x + size.height + 12, y: 0))
                stripes.addLine(to: CGPoint(x: x + 12, y: size.height))
                stripes.closeSubpath()
                x += 24
            }
            context.fill(stripes, with: .color(color.opacity(0.9)))
        }.accessibilityHidden(true)
    }
}

/// Each protection state is shown by an original TV-head mascot in sticker style: an inked body with a hard
/// shadow and misregistered print ghosts, a scanline screen whose face follows the state, wobbling antennae
/// and a gentle bob. Acid and smiling while guarding, hot pink behind warning stripes when locked,
/// amber with static while unconfirmed, grey with the screen off when idle.
private struct PlanetStyle {
    var base: Color
    var band: Color
    var shade: Color
    var ring: Color
    var tag: Color
    var tagText: Color
    var label: String
    var ghost: Double
    var speed: Double
    var face: Color
    init(_ indicator: GuardIndicator) {
        switch indicator {
        case .protecting:
            base = Zine.acid; band = Zine.rgb(0x9BE000); shade = Zine.rgb(0x1D6B3A); ring = Zine.acid
            tag = Zine.hot; tagText = Color.white; label = "SAFE!"; ghost = 1; speed = 1; face = Zine.cyan
        case .locked:
            base = Zine.hot; band = Zine.rgb(0xD81B60); shade = Zine.rgb(0x5A0B2A); ring = Zine.amber
            tag = Zine.acid; tagText = Zine.ink; label = "LOCKED"; ghost = 1; speed = 0.8; face = Zine.acid
        case .attention:
            base = Zine.amber; band = Zine.rgb(0xF08A00); shade = Zine.rgb(0x6B3A00); ring = Zine.acid
            tag = Zine.cyan; tagText = Zine.ink; label = "CHECK?"; ghost = 1; speed = 1.2; face = Zine.cyan
        case .inactive:
            base = Zine.rgb(0xA8A8B3); band = Zine.rgb(0x85858F); shade = Zine.rgb(0x3A3A42); ring = Zine.rgb(0xD0D0D6)
            tag = Zine.rgb(0x2A2A30); tagText = Color.white; label = "OFF"; ghost = 0.4; speed = 0.5; face = Zine.rgb(0x6B6B76)
        }
    }
    var english: String {
        switch label {
        case "SAFE!": return "ONLINE"
        case "LOCKED": return "LOCKED"
        case "CHECK?": return "CHECKING"
        default: return "OFFLINE"
        }
    }
}

private struct PlanetView: View {
    var indicator: GuardIndicator
    var animated: Bool
    var body: some View {
        let style = PlanetStyle(indicator)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { timeline in
            Canvas { context, size in
                PlanetView.draw(in: &context, size: size, style: style, indicator: indicator,
                                time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            }
        }.accessibilityHidden(true)
    }

    private static func circle(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    private static func spark(_ center: CGPoint, _ size: CGFloat) -> Path {
        var path = Path()
        for index in 0..<8 {
            let angle = Double(index) * Double.pi / 4 - Double.pi / 2
            let reach = index % 2 == 0 ? size : size * 0.32
            let point = CGPoint(x: center.x + reach * CGFloat(cos(angle)), y: center.y + reach * CGFloat(sin(angle)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, style: PlanetStyle, indicator: GuardIndicator, time: Double) {
        let unit: CGFloat = min(size.width / 1.5, size.height)
        let detailed = unit > 80
        let bodyH: CGFloat = unit * 0.56
        let bodyW: CGFloat = bodyH * 1.38
        let bob: CGFloat = CGFloat(sin(time * 2.6 * style.speed)) * unit * 0.018
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + unit * 0.09 + bob)
        let bodyRect = CGRect(x: center.x - bodyW / 2, y: center.y - bodyH / 2, width: bodyW, height: bodyH)
        let line: CGFloat = max(1.5, unit * 0.02)
        let shell = Path(roundedRect: bodyRect, cornerRadius: bodyH * 0.2)

        // Antennae, wobbling out of phase.
        for side in [-1.0, 1.0] {
            let sway: CGFloat = CGFloat(sin(time * 3.4 * style.speed + side * 1.3)) * unit * 0.025
            let base = CGPoint(x: center.x + CGFloat(side) * bodyW * 0.1, y: bodyRect.minY + line)
            let tip = CGPoint(x: center.x + CGFloat(side) * bodyW * 0.3 + sway, y: bodyRect.minY - bodyH * 0.42)
            var stalk = Path()
            stalk.move(to: base)
            stalk.addLine(to: tip)
            context.stroke(stalk, with: .color(Zine.ink), style: StrokeStyle(lineWidth: line * 1.3, lineCap: .round))
            let knob = circle(tip, max(2, unit * 0.03))
            context.fill(knob, with: .color(side < 0 ? Zine.hot : Zine.cyan))
            context.stroke(knob, with: .color(Zine.ink), lineWidth: line * 0.8)
        }

        // Stubby feet.
        for side in [-1.0, 1.0] {
            let foot = Path(roundedRect: CGRect(x: center.x + CGFloat(side) * bodyW * 0.26 - bodyW * 0.08, y: bodyRect.maxY - line,
                                                width: bodyW * 0.16, height: bodyH * 0.13), cornerRadius: bodyH * 0.04)
            context.fill(foot, with: .color(Zine.ink))
        }

        // Misregistered print ghosts and the sticker shadow.
        let wobble: CGFloat = CGFloat(sin(time * 3.1)) * unit * 0.004
        context.fill(shell.offsetBy(dx: -unit * 0.022 - wobble, dy: -unit * 0.012), with: .color(Zine.cyan.opacity(0.85 * style.ghost)))
        context.fill(shell.offsetBy(dx: unit * 0.024 + wobble, dy: unit * 0.02), with: .color(Zine.hot.opacity(0.85 * style.ghost)))
        context.fill(shell.offsetBy(dx: unit * 0.03, dy: unit * 0.035), with: .color(Zine.ink))
        context.fill(shell, with: .color(style.base))
        // A flat lighter panel band across the top of the cabinet.
        context.drawLayer { layer in
            layer.clip(to: shell)
            layer.fill(Path(CGRect(x: bodyRect.minX, y: bodyRect.minY, width: bodyW, height: bodyH * 0.1)), with: .color(Color.white.opacity(0.35)))
        }
        context.stroke(shell, with: .color(Zine.ink), lineWidth: line * 1.2)

        let screenRect = CGRect(x: bodyRect.minX + bodyW * 0.08, y: bodyRect.minY + bodyH * 0.14,
                                width: bodyW * 0.7, height: bodyH * 0.72)
        let glass = Path(roundedRect: screenRect, cornerRadius: bodyH * 0.12)
        context.fill(glass, with: .color(Zine.rgb(0x07100F)))
        drawScreen(in: &context, glass: glass, rect: screenRect, style: style, indicator: indicator, time: time, line: line)
        context.stroke(glass, with: .color(Zine.ink), lineWidth: line)

        // Knobs and a speaker grille on the right.
        let panelX: CGFloat = screenRect.maxX + (bodyRect.maxX - screenRect.maxX) / 2
        for index in 0..<2 {
            let knob = circle(CGPoint(x: panelX, y: screenRect.minY + screenRect.height * (0.2 + CGFloat(index) * 0.3)), bodyH * 0.075)
            context.fill(knob, with: .color(index == 0 ? Zine.hot : Zine.ink))
            context.stroke(knob, with: .color(Zine.ink), lineWidth: line * 0.8)
        }
        if detailed {
            for index in 0..<3 {
                let y = screenRect.minY + screenRect.height * (0.72 + CGFloat(index) * 0.1)
                context.fill(Path(CGRect(x: panelX - bodyH * 0.08, y: y, width: bodyH * 0.16, height: line * 0.8)), with: .color(Zine.ink))
            }
        }

        guard detailed else { return }

        // Sticker label, wobbling slightly.
        context.drawLayer { layer in
            layer.translateBy(x: bodyRect.maxX - bodyW * 0.02, y: bodyRect.minY - bodyH * 0.06)
            layer.rotate(by: .degrees(10 + 3 * sin(time * 2)))
            let tag = Path(CGRect(x: -unit * 0.17, y: -unit * 0.052, width: unit * 0.34, height: unit * 0.104))
            layer.fill(tag.offsetBy(dx: 3, dy: 3), with: .color(Zine.ink))
            layer.fill(tag, with: .color(style.tag))
            layer.stroke(tag, with: .color(Zine.ink), lineWidth: 2.5)
            layer.draw(Text(style.label).font(.system(size: unit * 0.058, weight: .black)).italic().foregroundColor(style.tagText),
                       at: .zero, anchor: .center)
        }

        let sparks: [(CGFloat, CGFloat, CGFloat, Double, Color)] = [(-0.62, -0.28, 0.055, 0, Zine.acid), (0.66, 0.24, 0.045, 1.9, Zine.cyan),
                                                                    (-0.5, 0.32, 0.03, 3.3, Color.white)]
        for item in sparks {
            let twinkle = 0.5 + 0.5 * sin(time * 2.4 + item.3)
            let point = CGPoint(x: center.x + item.0 * unit, y: center.y + item.1 * unit)
            let star = spark(point, item.2 * unit * CGFloat(0.65 + 0.35 * twinkle))
            context.fill(star, with: .color(item.4))
            context.stroke(star, with: .color(Zine.ink), lineWidth: 1.5)
        }
    }

    private static func drawScreen(in context: inout GraphicsContext, glass: Path, rect: CGRect, style: PlanetStyle,
                                   indicator: GuardIndicator, time: Double, line: CGFloat) {
        context.drawLayer { layer in
            layer.clip(to: glass)
            if indicator == .inactive {
                // Screen off: a faint reflection and a pulsing standby dot.
                layer.fill(Path(CGRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.14,
                                       width: rect.width * 0.22, height: rect.height * 0.08)), with: .color(Color.white.opacity(0.12)))
                let pulse = 0.45 + 0.4 * sin(time * 2.2)
                let dot = circle(CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY - rect.height * 0.18), max(1.5, rect.height * 0.045))
                layer.fill(dot, with: .color(Zine.hot.opacity(pulse)))
                return
            }
            if indicator == .locked {
                // Warning stripes crawling behind the face.
                let band = rect.height * 0.22
                let shift = CGFloat(time * 18).truncatingRemainder(dividingBy: band * 2)
                var stripes = Path()
                var x = rect.minX - rect.height - band * 2 + shift
                while x < rect.maxX + band {
                    stripes.move(to: CGPoint(x: x, y: rect.maxY))
                    stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    stripes.addLine(to: CGPoint(x: x + rect.height + band, y: rect.minY))
                    stripes.addLine(to: CGPoint(x: x + band, y: rect.maxY))
                    stripes.closeSubpath()
                    x += band * 2
                }
                layer.fill(stripes, with: .color(Zine.hot.opacity(0.35)))
            }
            if indicator == .attention {
                // Static noise that reshuffles every frame tick.
                var seed = UInt64(time * 12) &* 2654435761 &+ 1
                var noise = Path()
                let grain = max(1, rect.height * 0.03)
                for _ in 0..<70 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let px = rect.minX + CGFloat(seed >> 40) / CGFloat(1 << 24) * rect.width
                    let py = rect.minY + CGFloat((seed >> 16) & 0xFFFFFF) / CGFloat(1 << 24) * rect.height
                    noise.addRect(CGRect(x: px, y: py, width: grain, height: grain))
                }
                layer.fill(noise, with: .color(Color.white.opacity(0.22)))
            }

            // A glitch every few seconds nudges the face sideways.
            let cycle = time.truncatingRemainder(dividingBy: 3.4)
            let jump: CGFloat = cycle < 0.12 ? rect.width * 0.05 : 0
            layer.translateBy(x: jump, y: 0)
            drawFace(in: &layer, rect: rect, style: style, indicator: indicator, time: time, line: line)
            layer.translateBy(x: -jump, y: 0)

            // Scanlines and a slow rolling bar.
            var scan = Path()
            var y = rect.minY
            let gap = max(2, rect.height * 0.04)
            while y < rect.maxY {
                scan.addRect(CGRect(x: rect.minX, y: y, width: rect.width, height: gap * 0.4))
                y += gap
            }
            layer.fill(scan, with: .color(Color.black.opacity(0.28)))
            let roll = rect.minY + CGFloat((time * 0.5).truncatingRemainder(dividingBy: 1)) * rect.height
            layer.fill(Path(CGRect(x: rect.minX, y: roll, width: rect.width, height: rect.height * 0.1)), with: .color(style.face.opacity(0.08)))
        }
    }

    private static func drawFace(in context: inout GraphicsContext, rect: CGRect, style: PlanetStyle,
                                 indicator: GuardIndicator, time: Double, line: CGFloat) {
        let stroke = StrokeStyle(lineWidth: max(1.5, rect.height * 0.075), lineCap: .square, lineJoin: .miter)
        let eyeY = rect.midY - rect.height * 0.08
        let spread = rect.width * 0.2
        let s = rect.height * 0.12
        let blink = time.truncatingRemainder(dividingBy: 2.8) < 0.16
        var features = Path()
        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: rect.midX + CGFloat(side) * spread, y: eyeY)
            switch indicator {
            case .protecting:
                if blink {
                    features.move(to: CGPoint(x: eye.x - s, y: eye.y)); features.addLine(to: CGPoint(x: eye.x + s, y: eye.y))
                } else {
                    features.move(to: CGPoint(x: eye.x - s, y: eye.y + s * 0.6))
                    features.addLine(to: CGPoint(x: eye.x, y: eye.y - s * 0.6))
                    features.addLine(to: CGPoint(x: eye.x + s, y: eye.y + s * 0.6))
                }
            case .locked:
                // > <
                let dir = CGFloat(-side)
                features.move(to: CGPoint(x: eye.x - s * dir, y: eye.y - s * 0.7))
                features.addLine(to: CGPoint(x: eye.x + s * dir, y: eye.y))
                features.addLine(to: CGPoint(x: eye.x - s * dir, y: eye.y + s * 0.7))
            default:
                break
            }
        }
        switch indicator {
        case .protecting:
            features.move(to: CGPoint(x: rect.midX - s * 0.8, y: rect.midY + rect.height * 0.16))
            features.addLine(to: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.24))
            features.addLine(to: CGPoint(x: rect.midX + s * 0.8, y: rect.midY + rect.height * 0.16))
        case .locked:
            features.move(to: CGPoint(x: rect.midX - s * 0.9, y: rect.midY + rect.height * 0.22))
            features.addLine(to: CGPoint(x: rect.midX + s * 0.9, y: rect.midY + rect.height * 0.22))
        default:
            break
        }
        context.drawLayer { glow in
            glow.addFilter(.shadow(color: style.face.opacity(0.9), radius: rect.height * 0.06))
            glow.stroke(features, with: .color(style.face), style: stroke)
            if indicator == .attention {
                let wiggle = CGFloat(sin(time * 5)) * rect.height * 0.02
                let font = Font.system(size: rect.height * 0.42, weight: .black, design: .monospaced)
                for side in [-1.0, 1.0] {
                    glow.draw(Text("?").font(font).foregroundColor(style.face),
                              at: CGPoint(x: rect.midX + CGFloat(side) * spread, y: eyeY + wiggle * CGFloat(side)), anchor: .center)
                }
                var mouth = Path()
                mouth.move(to: CGPoint(x: rect.midX - s * 0.7, y: rect.midY + rect.height * 0.24))
                mouth.addLine(to: CGPoint(x: rect.midX - s * 0.2, y: rect.midY + rect.height * 0.19))
                mouth.addLine(to: CGPoint(x: rect.midX + s * 0.3, y: rect.midY + rect.height * 0.25))
                mouth.addLine(to: CGPoint(x: rect.midX + s * 0.8, y: rect.midY + rect.height * 0.2))
                glow.stroke(mouth, with: .color(style.face), style: stroke)
            }
        }
    }
}

struct GuardView: View {
    @StateObject private var model: GuardModel
    @State private var page: GuardPage = .overview
    @State private var hoveredTab: GuardPage?
    @State private var hoveringBoot = false
    @State private var confirmUninstall = false
    @Namespace private var tabSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: GuardModel = GuardModel()) { _model = StateObject(wrappedValue: model) }

    private var indicator: GuardIndicator { GuardIndicator(phase: model.phase) }
    private var planet: PlanetStyle { PlanetStyle(indicator) }
    private var stateColor: Color { planet.base }
    private var summary: String {
        switch model.phase {
        case "protecting": return "增强模式与系统代理均已确认。Surge 退出或状态异常时，自动锁定本机网络。"
        case "disabled": return "网络已按备份恢复。准备好后，可随时重新开启守护。"
        case "locked": return "已触发断网保护。查看诊断，或关闭守护并恢复网络。"
        case "starting": return "正在确认增强模式与系统代理，状态会自动更新。"
        case "unknown", "error": return "暂时无法确认后台状态。查看诊断，或关闭守护并恢复网络。"
        default: return "Surge 异常时自动锁网。开启前，请同时打开增强模式与系统代理。"
        }
    }
    private func go(_ target: GuardPage) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { page = target }
    }
    var body: some View {
        ZStack {
            StreetBackdrop(tint: stateColor).ignoresSafeArea()
            VStack(spacing: 0) {
                navigation.frame(height: 82)
                Group {
                    switch page {
                    case .overview: overview
                    case .settings: settings
                    case .diagnostics: diagnostics
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 30).padding(.bottom, 14)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(x: 18)))
                footer
            }
        }
        .foregroundColor(.white)
        .frame(width: 860, height: 640)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showDetails) { details }
    }

    private var navigation: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(GuardPage.allCases, id: \.self) { item in tabButton(item) }
            }
            HStack {
                Spacer()
                if model.preview {
                    Text("安全预览").font(.system(size: 12, weight: .black)).italic()
                        .padding(.horizontal, 16).frame(height: 26)
                        .modifier(Sticker(fill: Zine.hot))
                        .help("所有按钮只模拟状态，不安装组件，也不修改网络。")
                }
            }.padding(.horizontal, 30)
        }.padding(.top, 12)
    }
    private func tabButton(_ item: GuardPage) -> some View {
        let selected = page == item
        let hovered = hoveredTab == item
        let textColor: Color = selected ? Zine.ink : Color.white.opacity(hovered ? 0.95 : 0.6)
        let hint: String = "\(item.rawValue)（⌘\(String(item.shortcut.character))）"
        return Button { go(item) } label: {
            Text(item.rawValue).font(.system(size: 15, weight: .black))
                .foregroundColor(textColor)
                .frame(width: 96, height: 36)
                .background {
                    ZStack {
                        Slant().fill(Color.black).offset(x: 3, y: 3)
                        Slant().fill(hovered ? Zine.rgb(0x2E2E35) : Zine.rgb(0x26262B))
                        if selected {
                            Slant().fill(Zine.acid).matchedGeometryEffect(id: "tab", in: tabSelection)
                        }
                        Slant().stroke(Zine.ink, lineWidth: 2.5)
                    }
                }
                .offset(y: hovered && !selected ? -1.5 : 0)
                .contentShape(Slant())
                .animation(.easeOut(duration: 0.12), value: hovered)
        }.buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(item.shortcut, modifiers: .command)
            .help(hint)
            .onHover { inside in hoveredTab = inside ? item : (hoveredTab == item ? nil : hoveredTab) }
            .accessibilityIdentifier("tab-" + item.rawValue)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var overview: some View {
        VStack(spacing: 0) {
            PlanetView(indicator: indicator, animated: !reduceMotion)
                .frame(width: 440, height: 226)
                .id(indicator)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.85).combined(with: .opacity))
            HStack(spacing: 8) {
                Diamond(color: stateColor, size: 8)
                Text("网络保护 / " + planet.english).font(.system(size: 11, weight: .black)).tracking(2.5)
                if model.busy { ProgressView().controlSize(.mini).tint(stateColor) }
            }.foregroundColor(stateColor)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Rectangle().fill(Zine.ink))
                .overlay(Rectangle().stroke(stateColor, lineWidth: 2))
                .padding(.bottom, 12)
            headline(model.title, size: 40)
                .id(model.title).transition(.opacity)
            Text(summary).font(.system(size: 13, weight: .medium)).foregroundColor(Zine.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 480).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            Button { model.perform(model.primaryAction) } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.primaryAction == "enable" ? "power" : "network")
                    Text(model.primaryTitle)
                }.frame(minWidth: 190)
            }.buttonStyle(SlantButton(fill: model.primaryAction == "enable" ? Zine.acid : Color.white,
                                      shadow: model.primaryAction == "enable" ? Zine.hot : stateColor, large: true))
                .disabled(model.busy)
                .padding(.top, 20)
                .accessibilityIdentifier(model.primaryAction == "enable" ? "enableGuard" : "disableGuard")
            Spacer(minLength: 14)
            HStack(spacing: 14) {
                modeChip("增强模式")
                modeChip("系统代理")
                Button { go(.settings) } label: {
                    HStack(spacing: 8) {
                        Diamond(color: model.boot ? Zine.amber : Zine.edge)
                        Text("开机守护").foregroundColor(Zine.secondary)
                        Text(model.boot ? "已开启" : "未开启").fontWeight(.black)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .black))
                            .offset(x: hoveringBoot ? 3 : 0)
                    }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 18).frame(height: 32)
                        .modifier(Sticker(fill: hoveringBoot ? Zine.rgb(0x26262C) : Zine.panel, shadow: Color.black, border: Zine.edge))
                        .offset(y: hoveringBoot ? -1.5 : 0)
                        .contentShape(Slant())
                        .animation(.easeOut(duration: 0.12), value: hoveringBoot)
                }.buttonStyle(.plain).onHover { hoveringBoot = $0 }
                    .help(model.boot ? "系统启动时自动布防" : "由你手动开启保护")
                    .accessibilityIdentifier("openBootSettings")
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("异常后保持网络锁定，需手动关闭守护并恢复。")
            }.font(.system(size: 11, weight: .medium)).foregroundColor(Zine.subtle).padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.phase)
    }

    /// Heavy, slanted headline with an acid underbar and offset cyan / pink print ghosts.
    private func headline(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .black)).italic()
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 14)
            .background(alignment: .bottom) {
                Slant(lean: 0.6).fill(stateColor).frame(height: size * 0.36).offset(y: -size * 0.10)
            }
            .shadow(color: Zine.hot, radius: 0, x: 3, y: 3)
            .shadow(color: Zine.cyan, radius: 0, x: -2, y: -1)
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.16, d: 1, tx: size * 0.08, ty: 0))
    }

    private func modeChip(_ title: String) -> some View {
        let confirmed = model.phase == "protecting"
        let hint = confirmed ? "Surge 已确认" : (["disabled", "uninstalled"].contains(model.phase) ? "开启守护后持续检查" : "当前状态无法确认")
        return HStack(spacing: 8) {
            Diamond(color: confirmed ? stateColor : Zine.edge)
            Text(title).foregroundColor(Zine.secondary)
            Text(confirmed ? "已开启" : "待确认").fontWeight(.black)
        }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 18).frame(height: 32)
            .modifier(Sticker(fill: Zine.panel, shadow: Color.black, border: Zine.edge))
            .help(hint)
            .accessibilityElement(children: .combine)
            .accessibilityHint(hint)
    }

    private var settings: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            pageHeading("守护设置", kicker: GuardPage.settings.kicker, subtitle: "按你的习惯，安排每一次连接。")
            timeoutEditor
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    settingIcon("sunrise", tint: Zine.amber)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开机自动启动守护").font(.system(size: 14, weight: .black))
                        Text("后台随系统启动，无需打开窗口。").font(.system(size: 12)).foregroundColor(Zine.secondary)
                    }
                    Spacer()
                    Toggle("开机自动启动守护", isOn: Binding(get: { model.boot }, set: { model.setBoot($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Zine.acid)
                        .disabled(model.busy).accessibilityIdentifier("startAtBoot")
                }
                Rectangle().fill(Zine.edge).frame(height: 1)
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Zine.amber).padding(.top, 1)
                    Text("开机时 Surge 未就绪也会锁网。关闭守护后若保留此选项，下次开机会重新布防。")
                        .foregroundColor(Zine.secondary).lineSpacing(4)
                }.font(.system(size: 12))
            }.padding(20).modifier(ComicPanel(spine: Zine.amber))
            HStack(alignment: .top, spacing: 14) {
                settingIcon("key.horizontal", tint: Zine.acid)
                VStack(alignment: .leading, spacing: 7) {
                    Text("一次授权，日常免密码").font(.system(size: 14, weight: .black))
                    Text("本版本首次操作需管理员授权，重启后仍然有效。\n更新界面签名、重装或修复权限组件时，可能需要重新授权。")
                        .font(.system(size: 12)).foregroundColor(Zine.secondary).lineSpacing(4)
                }
                Spacer()
            }.padding(20).modifier(ComicPanel(spine: Zine.acid))
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("卸载后台组件").font(.system(size: 12, weight: .black))
                    Text("先恢复网络，再移除守护和权限组件。").font(.system(size: 11)).foregroundColor(Zine.secondary)
                }
                Spacer()
                Button("卸载…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(SlantButton(fill: Zine.panel, text: Zine.hot, shadow: Zine.hot))
                    .disabled(model.busy || !model.installed)
                    .accessibilityIdentifier("uninstallGuard")
                    .confirmationDialog("确定卸载后台组件？", isPresented: $confirmUninstall) {
                        Button("恢复网络并卸载", role: .destructive) { model.perform("uninstall") }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将先停止守护并按备份恢复网络，再移除守护和权限组件。")
                    }
            }.padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 8)
        }.frame(maxWidth: 660).frame(maxWidth: .infinity)
        }
    }

    private var timeoutEditor: some View {
        let unchanged = model.parsedTimeout == nil || model.parsedTimeout == model.timeoutMS
        let fieldBorder: Color = model.timeoutInputError == nil ? Zine.edge : Zine.hot
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                settingIcon("waveform.path", tint: Zine.cyan)
                VStack(alignment: .leading, spacing: 5) {
                    Text("无响应超时").font(.system(size: 14, weight: .black))
                    Text("默认 200 ms · 输入 10～10000 的整数")
                        .font(.system(size: 11)).foregroundColor(Zine.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    TextField("200", text: $model.timeoutText)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .onSubmit { model.saveTimeout() }
                        .accessibilityIdentifier("timeoutInput")
                    Text("ms").font(.system(size: 11, weight: .bold)).foregroundColor(Zine.secondary)
                }.padding(.horizontal, 12).frame(width: 112, height: 36)
                    .background(Rectangle().fill(Zine.ink))
                    .overlay(Rectangle().stroke(fieldBorder, lineWidth: 2))
                    .disabled(model.busy)
                Button("保存") { model.saveTimeout() }.buttonStyle(SlantButton())
                    .disabled(model.busy || unchanged)
                    .accessibilityIdentifier("saveTimeout")
            }
            Rectangle().fill(Zine.edge).frame(height: 1)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = model.timeoutInputError {
                        Text(error).foregroundColor(Zine.hot)
                    } else {
                        Text(model.timeoutCaption).foregroundColor(Zine.secondary)
                    }
                    Text("数值越小越敏感，越大越能容忍卡顿。明确的模式关闭或退出事件不等待此超时。")
                        .foregroundColor(Zine.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).lineSpacing(3)
                Spacer(minLength: 12)
                Button("恢复默认") { model.resetTimeout() }.buttonStyle(HoverLink())
                    .disabled(model.busy)
                    .accessibilityIdentifier("resetTimeout")
            }
            if model.engineOutdated {
                Text("旧版后台尚待升级，请先用旧版关闭并恢复网络。")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Zine.amber)
            }
        }.padding(20).modifier(ComicPanel(spine: Zine.cyan))
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                pageHeading("运行诊断", kicker: GuardPage.diagnostics.kicker, subtitle: "查看后台状态，找到每一次锁网的原因。")
                Spacer()
                Button { model.perform("diagnostics") } label: { Label("读取诊断", systemImage: "arrow.clockwise") }
                    .buttonStyle(SlantButton(fill: Zine.cyan, shadow: Zine.hot))
                    .disabled(model.busy).accessibilityIdentifier("readDiagnostics")
                    .padding(.top, 8)
            }
            HStack(spacing: 14) {
                PlanetView(indicator: indicator, animated: !reduceMotion).frame(width: 52, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.system(size: 14, weight: .black))
                    Text(model.detail).font(.system(size: 11)).foregroundColor(Zine.secondary).lineLimit(1)
                }
                Spacer()
                Text("LIVE · 约每秒刷新").font(.system(size: 10, weight: .black)).tracking(1).foregroundColor(stateColor)
            }.padding(.horizontal, 16).padding(.vertical, 10).modifier(ComicPanel(spine: stateColor))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("LOG").font(.system(size: 11, weight: .black)).italic().foregroundColor(Zine.ink)
                        .padding(.horizontal, 12).frame(height: 20)
                        .modifier(Sticker(fill: Zine.acid, depth: 2))
                    Text("最近操作输出").font(.system(size: 11, weight: .bold)).foregroundColor(Zine.secondary)
                    Spacer()
                    if !model.output.isEmpty {
                        Button("展开 ›") { model.showDetails = true }.buttonStyle(HoverLink())
                    }
                }.padding(.horizontal, 16).padding(.vertical, 11)
                CautionTape().frame(height: 6)
                if model.output.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .bold)).foregroundColor(Zine.subtle)
                        Text("还没有诊断记录").font(.system(size: 14, weight: .black))
                        Text("点击“读取诊断”，获取当前状态和最近日志。")
                            .font(.system(size: 12)).foregroundColor(Zine.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundColor(Zine.acid.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }.frame(maxHeight: .infinity)
                .background(Rectangle().fill(Zine.ink))
                .overlay(Rectangle().stroke(Zine.edge, lineWidth: 1.5))
                .background(Rectangle().fill(Color.black).offset(x: 5, y: 5))
            Label("读取状态不会主动触发断网。", systemImage: "info.circle")
                .font(.system(size: 11, weight: .medium)).foregroundColor(Zine.secondary).padding(.horizontal, 3)
        }.frame(maxWidth: 740).frame(maxWidth: .infinity)
    }

    private func pageHeading(_ title: String, kicker: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker).font(.system(size: 10, weight: .black)).tracking(3).foregroundColor(stateColor)
            Text(title).font(.system(size: 26, weight: .black)).italic()
                .padding(.trailing, 10)
                .background(alignment: .bottom) {
                    Slant(lean: 0.6).fill(stateColor.opacity(0.85)).frame(height: 9).offset(y: -3)
                }
                .shadow(color: Zine.hot, radius: 0, x: 2, y: 2)
            Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundColor(Zine.secondary).padding(.top, 2)
        }.padding(.bottom, 2)
    }
    private func settingIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .bold)).foregroundColor(Zine.ink)
            .frame(width: 40, height: 40)
            .background(Rectangle().fill(tint))
            .overlay(Rectangle().stroke(Zine.ink, lineWidth: 2))
            .background(Rectangle().fill(Color.black).offset(x: 3, y: 3))
            .rotationEffect(.degrees(-4))
    }
    private var footer: some View {
        VStack(spacing: 0) {
            CautionTape(color: stateColor).frame(height: 8)
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini).tint(stateColor) }
                else { Image(systemName: "menubar.rectangle").foregroundColor(Zine.subtle) }
                Text(model.activity.isEmpty ? "关闭窗口后，可从菜单栏打开。" : model.activity)
                    .font(.system(size: 11)).foregroundColor(Zine.secondary).lineLimit(1)
                if !model.output.isEmpty {
                    Button("查看详情") { model.showDetails = true }.buttonStyle(HoverLink())
                }
                Spacer(minLength: 12)
                Text("⌘1 守护 · ⌘2 设置 · ⌘3 诊断").font(.system(size: 10, weight: .medium)).foregroundColor(Zine.subtle)
                Text(model.preview ? "SAFE PREVIEW" : "SURGE GUARD // 2.3.0")
                    .font(.system(size: 10, weight: .black)).italic().tracking(1)
                    .foregroundColor(stateColor).padding(.leading, 8)
            }.padding(.horizontal, 30).frame(height: 38)
                .background(Zine.footer)
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("操作详情").font(.system(size: 20, weight: .black)).italic()
                    .shadow(color: Zine.hot, radius: 0, x: 2, y: 2)
                Spacer()
                Button("完成") { model.showDetails = false }.keyboardShortcut(.defaultAction)
                    .buttonStyle(SlantButton())
            }
            ScrollView {
                Text(model.output.isEmpty ? model.activity : model.output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .foregroundColor(Zine.acid.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading).padding(17)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Rectangle().fill(Zine.ink))
                .overlay(Rectangle().stroke(Zine.edge, lineWidth: 1.5))
        }.padding(24).frame(width: 710, height: 450)
            .background(Zine.bg).preferredColorScheme(.dark)
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
