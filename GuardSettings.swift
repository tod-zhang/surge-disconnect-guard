import Foundation

struct SettingsFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
struct GuardSettings: Codable, Equatable {
    static let defaultTimeoutMS = 200
    static let minimumTimeoutMS = 10
    static let maximumTimeoutMS = 10_000
    static let path = "/Library/Application Support/SurgeDisconnectGuard/settings.json"
    static let publicPath = "/var/run/local.surgedisconnect.settings.json"
    let timeoutMS: Int
    init(timeoutMS: Int = defaultTimeoutMS) throws {
        guard (Self.minimumTimeoutMS...Self.maximumTimeoutMS).contains(timeoutMS) else {
            throw SettingsFailure("请输入 10～10000 ms 的整数。")
        }
        self.timeoutMS = timeoutMS
    }
    static func parse(_ text: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let ms = Int(value) else {
            throw SettingsFailure("请输入 10～10000 ms 的整数。")
        }
        return try GuardSettings(timeoutMS: ms).timeoutMS
    }
    static func load(from path: String = path) throws -> GuardSettings {
        guard FileManager.default.fileExists(atPath: path) else { return try GuardSettings() }
        let decoded = try JSONDecoder().decode(GuardSettings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        return try GuardSettings(timeoutMS: decoded.timeoutMS)
    }
    func save(to path: String, permissions: Int = 0o600) throws {
        _ = try GuardSettings(timeoutMS: timeoutMS)
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }
}
func settingsSelfTest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guard-settings-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("settings.json").path
    guard try GuardSettings.load(from: path).timeoutMS == 200 else { throw SettingsFailure("默认超时错误") }
    for value in [10, 200, 750, 10000] {
        let settings = try GuardSettings(timeoutMS: value)
        try settings.save(to: path)
        guard try GuardSettings.load(from: path) == settings,
              try GuardSettings.parse(" \(value) ") == value else { throw SettingsFailure("设置保存或输入解析错误") }
    }
    for input in ["", "0", "-1", "9", "10001", "1.5", "nan", "200; whoami", "999999999999999999999"] {
        var rejected = false
        do { _ = try GuardSettings.parse(input) } catch { rejected = true }
        guard rejected else { throw SettingsFailure("未拒绝无效超时输入") }
    }
    try Data("{\"timeoutMS\":0}".utf8).write(to: URL(fileURLWithPath: path))
    var rejected = false
    do { _ = try GuardSettings.load(from: path) } catch { rejected = true }
    guard rejected else { throw SettingsFailure("未拒绝损坏设置") }
    print("PASS 默认 200ms、边界/自定义值、原子保存重读及非法输入/配置拒绝；仅临时目录。")
}
