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
}

private enum GuardPalette {
    static let mint = Color(red: 0.40, green: 0.87, blue: 0.69)
    static let blue = Color(red: 0.48, green: 0.70, blue: 0.95)
    static let gold = Color(red: 0.86, green: 0.75, blue: 0.48)
    static let secondary = Color.white.opacity(0.56)
    static let subtle = Color.white.opacity(0.34)
    static let space = Color(red: 0.045, green: 0.05, blue: 0.075)
    static let spaceLift = Color(red: 0.075, green: 0.085, blue: 0.115)
}

/// Each protection state is drawn as an anime-style, cel-shaded planet: flat colour fills with a hard
/// terminator shadow, ink outlines, drifting cloud bands and spots, a tilted ring and twinkling sparkles.
/// Mint while guarding, coral when locked, butter yellow while unconfirmed, lavender-grey when idle.
private struct PlanetStyle {
    var base: Color
    var light: Color
    var shadow: Color
    var band: Color
    var spot: Color
    var ring: Color
    var ringInner: Color
    var ink: Color
    var glow: Color
    var speed: Double
    var moon: Bool
    init(_ indicator: GuardIndicator) {
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch indicator {
        case .protecting:
            base = rgb(0x5EEAD4); light = rgb(0xCCFBF1); shadow = rgb(0x2B7A9E); band = rgb(0x99F6E4); spot = rgb(0x38BDF8)
            ring = rgb(0xFDE68A); ringInner = rgb(0xF9A8D4); ink = rgb(0x0F2A3D); glow = rgb(0x5EEAD4); speed = 1; moon = true
        case .locked:
            base = rgb(0xFB7185); light = rgb(0xFFE4E6); shadow = rgb(0x9F1239); band = rgb(0xFDA4AF); spot = rgb(0xF97316)
            ring = rgb(0xFCD34D); ringInner = rgb(0xFB923C); ink = rgb(0x3B0A16); glow = rgb(0xFB7185); speed = 0.8; moon = false
        case .attention:
            base = rgb(0xFCD34D); light = rgb(0xFEF9C3); shadow = rgb(0xC2780E); band = rgb(0xFDE68A); spot = rgb(0xFB923C)
            ring = rgb(0xA5F3FC); ringInner = rgb(0xC4B5FD); ink = rgb(0x3D2604); glow = rgb(0xFACC15); speed = 1.2; moon = false
        case .inactive:
            base = rgb(0xA5B4CF); light = rgb(0xE2E8F0); shadow = rgb(0x4B5675); band = rgb(0xC7D2E5); spot = rgb(0x8B93B8)
            ring = rgb(0xCBD5E1); ringInner = rgb(0x94A3B8); ink = rgb(0x1A2033); glow = rgb(0x94A3B8); speed = 0.5; moon = false
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
                PlanetView.draw(in: &context, size: size, style: style,
                                time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            }
        }.accessibilityHidden(true)
    }

    private static func circle(_ point: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, style: PlanetStyle, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = min(size.width, size.height) * 0.30
        let ink: CGFloat = max(1, radius * 0.045)
        let breathe: Double = 0.8 + 0.2 * sin(time * 1.6)

        // Soft halo behind everything.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.45))
            layer.fill(circle(center, radius * 1.12), with: .color(style.glow.opacity(0.35 * breathe)))
        }
        drawSparkles(in: &context, center: center, radius: radius, style: style, time: time)

        let tilt = -0.32 + 0.03 * sin(time * 0.5)
        if style.moon { drawMoon(in: &context, center: center, radius: radius, style: style, time: time, front: false) }
        drawRing(in: &context, center: center, radius: radius, tilt: tilt, style: style, front: false, ink: ink)
        drawBody(in: &context, center: center, radius: radius, style: style, time: time * style.speed, ink: ink)
        drawRing(in: &context, center: center, radius: radius, tilt: tilt, style: style, front: true, ink: ink)
        if style.moon { drawMoon(in: &context, center: center, radius: radius, style: style, time: time, front: true) }
    }

    private static func drawBody(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                                 style: PlanetStyle, time: Double, ink: CGFloat) {
        let body = circle(center, radius)
        context.drawLayer { layer in
            layer.clip(to: body)
            layer.fill(body, with: .color(style.base))

            // Wavy cloud bands that drift sideways as the planet turns.
            let bands: [(CGFloat, CGFloat)] = [(-0.62, 0.16), (-0.18, 0.12), (0.22, 0.20), (0.62, 0.10)]
            for (index, band) in bands.enumerated() {
                let phase = time * 0.6 + Double(index) * 1.7
                var path = Path()
                let steps = 40
                for step in 0...steps {
                    let x = center.x - radius + radius * 2 * CGFloat(step) / CGFloat(steps)
                    let wave = radius * 0.04 * CGFloat(sin(Double(x / radius) * 3 + phase))
                    let point = CGPoint(x: x, y: center.y + radius * band.0 + wave)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                for step in (0...steps).reversed() {
                    let x = center.x - radius + radius * 2 * CGFloat(step) / CGFloat(steps)
                    let wave = radius * 0.04 * CGFloat(sin(Double(x / radius) * 3 + phase + 1.2))
                    path.addLine(to: CGPoint(x: x, y: center.y + radius * (band.0 + band.1) + wave))
                }
                path.closeSubpath()
                layer.fill(path, with: .color(index % 2 == 0 ? style.band : style.light.opacity(0.55)))
            }

            // Spots ride around the sphere: longitude advances with time, width foreshortens near the limb.
            let spots: [(Double, CGFloat, CGFloat)] = [(0.0, -0.35, 0.16), (2.1, 0.40, 0.11), (4.0, 0.05, 0.08), (5.2, -0.05, 0.13)]
            for spot in spots {
                let longitude = (spot.0 + time * 0.45).truncatingRemainder(dividingBy: 2 * .pi)
                let facing = CGFloat(cos(longitude))
                guard facing > 0.05 else { continue }
                let latitude = spot.1
                let rowWidth = radius * CGFloat((1 - Double(latitude * latitude)).squareRoot())
                let x = center.x + rowWidth * CGFloat(sin(longitude))
                let y = center.y + radius * latitude
                let w = radius * spot.2 * facing, h = radius * spot.2 * 0.7
                let rect = CGRect(x: x - w, y: y - h, width: w * 2, height: h * 2)
                layer.fill(Path(ellipseIn: rect), with: .color(style.spot))
                layer.fill(Path(ellipseIn: rect.insetBy(dx: w * 0.35, dy: h * 0.35).offsetBy(dx: -w * 0.15, dy: -h * 0.15)),
                           with: .color(style.light.opacity(0.6)))
            }

            // Hard-edged cel shadow: everything outside the lit disc offset toward the light.
            var shade = Path()
            shade.addPath(body)
            shade.addPath(circle(CGPoint(x: center.x - radius * 0.28, y: center.y - radius * 0.30), radius * 1.06))
            layer.fill(shade, with: .color(style.shadow.opacity(0.62)), style: FillStyle(eoFill: true))

            // Thin rim light along the shadowed edge.
            var rim = Path()
            rim.addPath(body)
            rim.addPath(circle(CGPoint(x: center.x - radius * 0.07, y: center.y - radius * 0.07), radius))
            layer.fill(rim, with: .color(style.light.opacity(0.75)), style: FillStyle(eoFill: true))

            // Crisp anime highlight: a tilted oval plus a small dot.
            var oval = Path(ellipseIn: CGRect(x: -radius * 0.24, y: -radius * 0.11, width: radius * 0.48, height: radius * 0.22))
            oval = oval.applying(CGAffineTransform(rotationAngle: -0.7))
                .applying(CGAffineTransform(translationX: center.x - radius * 0.42, y: center.y - radius * 0.44))
            layer.fill(oval, with: .color(Color.white.opacity(0.92)))
            layer.fill(circle(CGPoint(x: center.x - radius * 0.14, y: center.y - radius * 0.66), radius * 0.05),
                       with: .color(Color.white.opacity(0.92)))
        }
        context.stroke(body, with: .color(style.ink), lineWidth: ink)
    }

    private static func drawRing(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, tilt: Double,
                                 style: PlanetStyle, front: Bool, ink: CGFloat) {
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(tilt))
            let halfHeight = radius * 2
            layer.clip(to: Path(CGRect(x: -radius * 3, y: front ? 0 : -halfHeight, width: radius * 6, height: halfHeight + (front ? 0 : 1))))
            func ellipse(_ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            }
            let outer = ellipse(radius * 1.78, radius * 0.46)
            let middle = ellipse(radius * 1.52, radius * 0.38)
            let inner = ellipse(radius * 1.30, radius * 0.31)
            var band1 = Path(); band1.addPath(outer); band1.addPath(middle)
            var band2 = Path(); band2.addPath(middle); band2.addPath(inner)
            layer.fill(band1, with: .color(style.ring), style: FillStyle(eoFill: true))
            layer.fill(band2, with: .color(style.ringInner), style: FillStyle(eoFill: true))
            layer.stroke(outer, with: .color(style.ink), lineWidth: ink)
            layer.stroke(middle, with: .color(style.ink.opacity(0.5)), lineWidth: ink * 0.5)
            layer.stroke(inner, with: .color(style.ink), lineWidth: ink)
        }
    }

    private static func drawMoon(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                                 style: PlanetStyle, time: Double, front: Bool) {
        let angle = time * 0.7
        guard (sin(angle) > 0) == front else { return }
        let raw = CGPoint(x: radius * 2.05 * CGFloat(cos(angle)), y: radius * 0.62 * CGFloat(sin(angle)))
            .applying(CGAffineTransform(rotationAngle: 0.25))
        let point = CGPoint(x: center.x + raw.x, y: center.y + raw.y - radius * 0.15)
        let r = radius * (front ? 0.16 : 0.13)
        let moon = circle(point, r)
        context.drawLayer { layer in
            layer.clip(to: moon)
            layer.fill(moon, with: .color(style.light))
            var shade = Path()
            shade.addPath(moon)
            shade.addPath(circle(CGPoint(x: point.x - r * 0.3, y: point.y - r * 0.3), r * 1.05))
            layer.fill(shade, with: .color(style.shadow.opacity(0.5)), style: FillStyle(eoFill: true))
            layer.fill(circle(CGPoint(x: point.x - r * 0.35, y: point.y - r * 0.35), r * 0.22), with: .color(Color.white))
        }
        context.stroke(moon, with: .color(style.ink), lineWidth: max(1, r * 0.16))
    }

    private static func drawSparkles(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                                     style: PlanetStyle, time: Double) {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(-1.55, -0.85, 0.16), (1.45, -0.95, 0.12), (1.75, 0.55, 0.10),
                                                    (-1.25, 0.95, 0.09), (0.35, -1.25, 0.08)]
        for (index, spot) in spots.enumerated() {
            let pulse = sin(time * 1.8 + Double(index) * 1.3)
            guard pulse > 0 else { continue }
            let s = radius * spot.2 * CGFloat(pulse)
            let p = CGPoint(x: center.x + radius * spot.0, y: center.y + radius * spot.1)
            var star = Path()
            star.move(to: CGPoint(x: p.x, y: p.y - s))
            star.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: p)
            star.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: p)
            star.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: p)
            star.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: p)
            context.fill(star, with: .color(index % 2 == 0 ? Color.white.opacity(0.9) : style.light.opacity(0.9)))
        }
    }
}

private struct Starfield: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x5EED_2300
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            for _ in 0..<110 {
                let x = next() * size.width, y = next() * size.height
                let r = 0.35 + next() * 0.9
                let alpha = 0.06 + Double(next()) * 0.32
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(Color.white.opacity(alpha)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Small status dot drawn like the planet: flat fill, inked edge and a glossy highlight.
private struct CelDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color)
            .overlay(Circle().fill(Color.white.opacity(0.9)).frame(width: size * 0.3, height: size * 0.3)
                .offset(x: -size * 0.16, y: -size * 0.16))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A handful of four-point sparkles, matching the planet's, that twinkle slowly over the starfield.
private struct Twinkles: View {
    var animated: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animated)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                let spots: [(CGFloat, CGFloat, CGFloat, Double)] = [(0.08, 0.20, 5, 0), (0.92, 0.30, 6, 1.7), (0.17, 0.62, 4, 3.1),
                                                                    (0.86, 0.70, 5, 4.4), (0.30, 0.10, 3, 2.2), (0.70, 0.14, 4, 5.3),
                                                                    (0.05, 0.88, 3, 0.9), (0.96, 0.92, 4, 3.8)]
                for spot in spots {
                    let twinkle = 0.5 + 0.5 * sin(time * 1.3 + spot.3)
                    let center = CGPoint(x: spot.0 * size.width, y: spot.1 * size.height)
                    let r = spot.2 * CGFloat(0.5 + 0.5 * twinkle)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x, y: center.y - r))
                    path.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: center)
                    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: center)
                    path.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: center)
                    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: center)
                    context.fill(path, with: .color(Color.white.opacity(0.15 + 0.55 * twinkle)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
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
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

/// Capsule button that lifts slightly on hover, in the spirit of a single clear call to action.
private struct PillButton: ButtonStyle {
    var prominent = false
    var tint: Color = .white
    /// Optional state colour: a hard, sticker-like drop edge on prominent buttons, a tinted outline otherwise.
    var edge: Color?
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, tint: tint, edge: edge)
    }
    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let tint: Color
        let edge: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let drop: CGFloat = configuration.isPressed ? 1 : (hovering && isEnabled ? 4 : 3)
            let outline: Color = prominent ? Color.clear : (edge?.opacity(hovering ? 0.75 : 0.45) ?? Color.white.opacity(0.10))
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20).frame(height: 40)
                .foregroundStyle(prominent ? Color.black.opacity(0.86) : Color.white.opacity(0.88))
                .background(Capsule().fill(prominent ? tint : Color.white.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.065)))
                .background {
                    if prominent, let edge = edge {
                        Capsule().fill(edge).offset(y: drop)
                    }
                }
                .overlay(Capsule().strokeBorder(outline, lineWidth: edge == nil ? 1 : 1.5))
                .offset(y: prominent && edge != nil && configuration.isPressed ? 2 : 0)
                .shadow(color: prominent ? tint.opacity(hovering ? 0.30 : 0.14) : Color.clear, radius: hovering ? 18 : 10, y: 4)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering && isEnabled ? 1.02 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Plain text-like button that brightens on hover.
private struct HoverLink: ButtonStyle {
    var tint: Color = GuardPalette.mint
    func makeBody(configuration: Configuration) -> some View {
        HoverLinkBody(configuration: configuration, tint: tint)
    }
    private struct HoverLinkBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : hovering ? 1 : 0.82))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
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
    private var accent: Color { planet.glow }
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
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { page = target }
    }
    var body: some View {
        ZStack {
            WindowMaterial().ignoresSafeArea()
            LinearGradient(colors: [GuardPalette.spaceLift.opacity(0.95), GuardPalette.space.opacity(0.98)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(page == .overview ? 0.12 : 0.05), .clear], center: UnitPoint(x: 0.5, y: 0.36),
                           startRadius: 10, endRadius: 430).ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: model.phase)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)
            Starfield().ignoresSafeArea()
            Twinkles(animated: !reduceMotion).ignoresSafeArea()
            VStack(spacing: 0) {
                navigation.frame(height: 78)
                Group {
                    switch page {
                    case .overview: overview
                    case .settings: settings
                    case .diagnostics: diagnostics
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 28).padding(.bottom, 16)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 10)))
                footer
            }
        }
        .foregroundStyle(.white)
        .frame(width: 860, height: 640)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showDetails) { details }
    }

    private var navigation: some View {
        ZStack {
            HStack(spacing: 2) {
                ForEach(GuardPage.allCases, id: \.self) { item in tabButton(item) }
            }.padding(5).background(Color.white.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            HStack {
                Spacer()
                if model.preview {
                    Label("安全预览", systemImage: "eye")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(GuardPalette.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.05), in: Capsule())
                        .help("所有按钮只模拟状态，不安装组件，也不修改网络。")
                }
            }.padding(.horizontal, 28)
        }.padding(.top, 8)
    }
    private func tabButton(_ item: GuardPage) -> some View {
        let selected = page == item
        let textColor: Color = selected ? Color.black.opacity(0.88) : Color.white.opacity(hoveredTab == item ? 0.86 : 0.55)
        let hint: String = "\(item.rawValue)（⌘\(String(item.shortcut.character))）"
        return Button { go(item) } label: {
            HStack(spacing: 7) {
                CelDot(color: tabDot(item), size: 7)
                    .opacity(page == item ? 1 : 0.8)
                Text(item.rawValue).font(.system(size: 13, weight: .semibold))
            }
            .frame(width: 92, height: 34)
            .foregroundStyle(textColor)
            .background {
                if page == item {
                    Capsule().fill(Color.white.opacity(0.96))
                        .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "tab", in: tabSelection)
                } else if hoveredTab == item {
                    Capsule().fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }.buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(item.shortcut, modifiers: .command)
            .help(hint)
            .onHover { inside in hoveredTab = inside ? item : (hoveredTab == item ? nil : hoveredTab) }
            .accessibilityIdentifier("tab-" + item.rawValue)
            .accessibilityAddTraits(page == item ? [.isSelected] : [])
    }
    private func tabDot(_ item: GuardPage) -> Color {
        switch item {
        case .overview: return planet.base
        case .settings: return GuardPalette.gold
        case .diagnostics: return GuardPalette.blue
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            PlanetView(indicator: indicator, animated: !reduceMotion)
                .frame(width: 420, height: 228)
                .id(indicator)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.9).combined(with: .opacity))
            HStack(spacing: 7) {
                CelDot(color: planet.base, size: 7)
                Text("网络保护").font(.system(size: 11, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(GuardPalette.secondary)
                if model.busy { ProgressView().controlSize(.mini).tint(accent) }
            }.padding(.bottom, 10)
            Text(model.title).font(.system(size: 34, weight: .semibold)).tracking(-0.6)
                .lineLimit(1).minimumScaleFactor(0.75)
                .id(model.title).transition(.opacity)
            Text(summary).font(.system(size: 13)).foregroundStyle(GuardPalette.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 440).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            Button { model.perform(model.primaryAction) } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.primaryAction == "enable" ? "power" : "network")
                    Text(model.primaryTitle)
                }.frame(minWidth: 168)
            }.buttonStyle(PillButton(prominent: model.primaryAction == "enable", edge: planet.shadow))
                .disabled(model.busy)
                .padding(.top, 22)
                .accessibilityIdentifier(model.primaryAction == "enable" ? "enableGuard" : "disableGuard")
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                modeChip("增强模式", tint: planet.base)
                modeChip("系统代理", tint: planet.base)
                Button { go(.settings) } label: {
                    HStack(spacing: 8) {
                        CelDot(color: model.boot ? GuardPalette.gold : Color.white.opacity(0.25))
                        Text("开机守护").foregroundStyle(GuardPalette.secondary)
                        Text(model.boot ? "已开启" : "未开启").fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(GuardPalette.subtle).offset(x: hoveringBoot ? 2 : 0)
                    }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 34)
                        .background(Color.white.opacity(hoveringBoot ? 0.09 : 0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .contentShape(Capsule())
                        .animation(.easeOut(duration: 0.15), value: hoveringBoot)
                }.buttonStyle(.plain).onHover { hoveringBoot = $0 }
                    .help(model.boot ? "系统启动时自动布防" : "由你手动开启保护")
                    .accessibilityIdentifier("openBootSettings")
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(GuardPalette.subtle)
                Text("异常后保持网络锁定，需手动关闭守护并恢复。").foregroundStyle(GuardPalette.subtle)
            }.font(.system(size: 11)).padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.phase)
    }

    private func modeChip(_ title: String, tint: Color) -> some View {
        let confirmed = model.phase == "protecting"
        let hint = confirmed ? "Surge 已确认" : (["disabled", "uninstalled"].contains(model.phase) ? "开启守护后持续检查" : "当前状态无法确认")
        return HStack(spacing: 8) {
            CelDot(color: confirmed ? tint : Color.white.opacity(0.25))
                .shadow(color: confirmed ? tint.opacity(0.7) : Color.clear, radius: 4)
            Text(title).foregroundStyle(GuardPalette.secondary)
            Text(confirmed ? "已开启" : "待确认").fontWeight(.semibold)
        }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 34)
            .background(Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .help(hint)
            .accessibilityElement(children: .combine)
            .accessibilityHint(hint)
    }

    private var settings: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
            pageHeading("守护设置", subtitle: "按你的习惯，安排每一次连接。")
            timeoutEditor
            VStack(alignment: .leading, spacing: 16) {
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
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(GuardPalette.gold).padding(.top, 1)
                    Text("开机时 Surge 未就绪也会锁网。关闭守护后若保留此选项，下次开机会重新布防。")
                        .foregroundStyle(GuardPalette.secondary).lineSpacing(4)
                }.font(.system(size: 12))
            }.padding(20).modifier(GlassPanel(radius: 18))
            HStack(alignment: .top, spacing: 14) {
                settingIcon("key.horizontal", tint: GuardPalette.mint)
                VStack(alignment: .leading, spacing: 7) {
                    Text("一次授权，日常免密码").font(.system(size: 14, weight: .semibold))
                    Text("本版本首次操作需管理员授权，重启后仍然有效。\n更新界面签名、重装或修复权限组件时，可能需要重新授权。")
                        .font(.system(size: 12)).foregroundStyle(GuardPalette.secondary).lineSpacing(4)
                }
                Spacer()
            }.padding(20).modifier(GlassPanel(radius: 18))
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("卸载后台组件").font(.system(size: 12, weight: .medium))
                    Text("先恢复网络，再移除守护和权限组件。").font(.system(size: 11)).foregroundStyle(GuardPalette.secondary)
                }
                Spacer()
                Button("卸载…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(PillButton()).disabled(model.busy || !model.installed)
                    .accessibilityIdentifier("uninstallGuard")
                    .confirmationDialog("确定卸载后台组件？", isPresented: $confirmUninstall) {
                        Button("恢复网络并卸载", role: .destructive) { model.perform("uninstall") }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将先停止守护并按备份恢复网络，再移除守护和权限组件。")
                    }
            }.padding(.horizontal, 4).padding(.top, 4)
        }.frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
    }

    private var timeoutEditor: some View {
        let unchanged = model.parsedTimeout == nil || model.parsedTimeout == model.timeoutMS
        return VStack(alignment: .leading, spacing: 15) {
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
                }.padding(.horizontal, 14).frame(width: 112, height: 40)
                    .background(Color.black.opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(model.timeoutInputError == nil ? Color.white.opacity(0.10) : Color.orange.opacity(0.6), lineWidth: 1))
                    .disabled(model.busy)
                Button("保存") { model.saveTimeout() }.buttonStyle(PillButton(prominent: true))
                    .disabled(model.busy || unchanged)
                    .accessibilityIdentifier("saveTimeout")
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
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
                Button("恢复默认") { model.resetTimeout() }.buttonStyle(HoverLink())
                    .font(.system(size: 11)).disabled(model.busy)
                    .accessibilityIdentifier("resetTimeout")
            }
            if model.engineOutdated {
                Text("旧版后台尚待升级，请先用旧版关闭并恢复网络。")
                    .font(.system(size: 11)).foregroundStyle(GuardPalette.gold)
            }
        }.padding(20).modifier(GlassPanel(radius: 18))
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                pageHeading("运行诊断", subtitle: "查看后台状态，找到每一次锁网的原因。")
                Spacer()
                Button { model.perform("diagnostics") } label: { Label("读取诊断", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButton()).disabled(model.busy).accessibilityIdentifier("readDiagnostics")
            }
            HStack(spacing: 14) {
                PlanetView(indicator: indicator, animated: !reduceMotion).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.system(size: 14, weight: .semibold))
                    Text(model.detail).font(.system(size: 11)).foregroundStyle(GuardPalette.secondary).lineLimit(1)
                }
                Spacer()
                Text("约每秒刷新").font(.system(size: 11)).foregroundStyle(GuardPalette.subtle)
            }.padding(.horizontal, 16).padding(.vertical, 12).modifier(GlassPanel(radius: 16))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34).opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18).opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25).opacity(0.8)).frame(width: 8, height: 8)
                    Label("最近操作输出", systemImage: "terminal").font(.system(size: 11, weight: .medium)).padding(.leading, 8)
                    Spacer()
                    if !model.output.isEmpty {
                        Button("展开") { model.showDetails = true }.buttonStyle(HoverLink()).font(.system(size: 11))
                    }
                }.foregroundStyle(GuardPalette.secondary).padding(.horizontal, 16).padding(.vertical, 13)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                if model.output.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(GuardPalette.subtle)
                        Text("还没有诊断记录").font(.system(size: 14, weight: .medium))
                        Text("点击“读取诊断”，获取当前状态和最近日志。")
                            .font(.system(size: 12)).foregroundStyle(GuardPalette.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(model.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(Color.white.opacity(0.76)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }.frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 18))
                .modifier(GlassPanel(radius: 18))
            Label("读取状态不会主动触发断网。", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary).padding(.horizontal, 3)
        }.frame(maxWidth: 720).frame(maxWidth: .infinity)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.3)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(GuardPalette.secondary)
        }.padding(.bottom, 2)
    }
    private func settingIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .regular)).foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(Circle().fill(RadialGradient(colors: [tint.opacity(0.22), tint.opacity(0.05)],
                                                     center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 30)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.mini).tint(GuardPalette.mint) }
            else { Image(systemName: "menubar.rectangle").foregroundStyle(GuardPalette.subtle) }
            Text(model.activity.isEmpty ? "关闭窗口后，可从菜单栏打开。" : model.activity)
                .font(.system(size: 11)).foregroundStyle(GuardPalette.secondary).lineLimit(1)
            if !model.output.isEmpty {
                Button("查看详情") { model.showDetails = true }.font(.system(size: 11)).buttonStyle(HoverLink())
            }
            Spacer(minLength: 12)
            Text("⌘1 守护 · ⌘2 设置 · ⌘3 诊断").font(.system(size: 10)).foregroundStyle(GuardPalette.subtle)
            Text(model.preview ? "安全预览" : "Surge 断网守护 · 2.3.0")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(GuardPalette.subtle).padding(.leading, 8)
        }.padding(.horizontal, 28).frame(height: 40)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("操作详情", systemImage: "terminal").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("完成") { model.showDetails = false }.keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButton(prominent: true))
            }
            ScrollView {
                Text(model.output.isEmpty ? model.activity : model.output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(Color.white.opacity(0.80)).frame(maxWidth: .infinity, alignment: .leading).padding(17)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }.padding(24).frame(width: 710, height: 450)
            .background(GuardPalette.spaceLift).preferredColorScheme(.dark)
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
