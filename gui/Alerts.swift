import Foundation
import AppKit
import ServiceManagement
import UserNotifications

enum GuardAlert: Equatable {
    case locked(reason: String)
    case restored
}

/// Turns the once-a-second status phase into at most one alert per lock and one per restore.
/// A stale status ("unknown") between two "locked" readings must not announce the same lock twice.
struct GuardAlertTracker {
    private(set) var lockAnnounced = false
    mutating func observe(phase: String, detail: String) -> GuardAlert? {
        switch phase {
        case "locked":
            guard !lockAnnounced else { return nil }
            lockAnnounced = true
            return .locked(reason: detail)
        case "disabled", "uninstalled", "protecting":
            guard lockAnnounced else { return nil }
            lockAnnounced = false
            // A manual restore passes through "disabled"; going straight back to "protecting" is an auto-restore.
            return .restored
        default:
            return nil
        }
    }
}

func alertContent(_ alert: GuardAlert, sound: Bool) -> (title: String, body: String, sound: Bool) {
    switch alert {
    case .locked(let reason):
        let cause = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return ("网络已锁定", (cause.isEmpty ? "守护检测到异常并断开了网络。" : "原因：" + cause) + "\n点击打开，可关闭守护并恢复网络。", sound)
    case .restored:
        return ("网络已恢复", "已按备份恢复网络。VPN 可能需要重新连接。", false)
    }
}

final class AlertSettings: ObservableObject {
    @Published var notify: Bool {
        didSet { UserDefaults.standard.set(notify, forKey: "alertNotify"); if notify { requestAuthorization() } }
    }
    @Published var sound: Bool {
        didSet { UserDefaults.standard.set(sound, forKey: "alertSound") }
    }
    @Published var notifyRestore: Bool {
        didSet { UserDefaults.standard.set(notifyRestore, forKey: "alertNotifyRestore") }
    }
    @Published private(set) var openAtLogin = false
    @Published private(set) var loginMessage = ""
    @Published private(set) var notificationsDenied = false
    let preview: Bool
    /// Notification and login-item APIs need a real app bundle; the self-test binary has none.
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    init(preview: Bool) {
        self.preview = preview
        notify = UserDefaults.standard.object(forKey: "alertNotify") as? Bool ?? true
        sound = UserDefaults.standard.object(forKey: "alertSound") as? Bool ?? true
        notifyRestore = UserDefaults.standard.object(forKey: "alertNotifyRestore") as? Bool ?? true
        refreshLoginItem()
    }

    func requestAuthorization() {
        guard !preview, hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationsDenied = !granted }
        }
    }

    func post(_ alert: GuardAlert) {
        guard !preview, hasBundle, notify else { return }
        if alert == .restored && !notifyRestore { return }
        let text = alertContent(alert, sound: sound)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        if text.sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: "guard-" + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { NSLog("无法发送断网提醒：%@", String(describing: error)) }
        }
    }

    func refreshLoginItem() {
        guard !preview, hasBundle else { loginMessage = preview ? "预览模式不修改登录项。" : ""; return }
        switch SMAppService.mainApp.status {
        case .enabled: openAtLogin = true; loginMessage = "登录后自动在菜单栏运行，断网时可及时提醒。"
        case .requiresApproval: openAtLogin = true; loginMessage = "需要在“系统设置 → 通用 → 登录项”中允许本应用。"
        default: openAtLogin = false; loginMessage = "未开启时，只有手动打开应用后才会收到断网提醒。"
        }
    }

    func setOpenAtLogin(_ value: Bool) {
        guard !preview, hasBundle else { openAtLogin = value; return }
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginMessage = "无法更改登录项：\(error.localizedDescription)"
        }
    }

    var needsLoginApproval: Bool { !preview && hasBundle && SMAppService.mainApp.status == .requiresApproval }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// True when macOS started the app as a login item, so it can stay in the menu bar without a window.
func launchedAsLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
          event.eventID == AEEventID(kAEOpenApplication) else { return false }
    return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
}

func alertSelfTest() -> Bool {
    var tracker = GuardAlertTracker()
    let sequence: [(String, GuardAlert?)] = [
        ("protecting", nil), ("locked", .locked(reason: "收到 Surge 主进程退出事件")), ("unknown", nil),
        ("locked", nil), ("disabled", .restored), ("disabled", nil), ("protecting", nil),
        ("locked", .locked(reason: "收到 Surge 主进程退出事件")), ("uninstalled", .restored),
        ("locked", .locked(reason: "收到 Surge 主进程退出事件")), ("starting", nil), ("protecting", .restored), ("protecting", nil)
    ]
    for (phase, expected) in sequence {
        guard tracker.observe(phase: phase, detail: "收到 Surge 主进程退出事件") == expected else { return false }
    }
    // An app opened after a boot-time lock still announces the lock it finds.
    var fresh = GuardAlertTracker()
    guard fresh.observe(phase: "locked", detail: "未发现 Surge 主进程") == .locked(reason: "未发现 Surge 主进程") else { return false }
    let locked = alertContent(.locked(reason: " 系统代理有效配置已关闭 "), sound: true)
    guard locked.title == "网络已锁定", locked.body.hasPrefix("原因：系统代理有效配置已关闭\n"), locked.sound else { return false }
    guard alertContent(.locked(reason: ""), sound: false).body.hasPrefix("守护检测到异常"),
          !alertContent(.restored, sound: true).sound else { return false }
    return true
}
