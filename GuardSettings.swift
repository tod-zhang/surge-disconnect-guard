import Foundation

struct SettingsFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
struct GuardSettings: Codable, Equatable {
    static let defaultTimeoutMS = 200
    static let minimumTimeoutMS = 10
    static let maximumTimeoutMS = 10_000
    static let defaultIntervalMS = 20
    static let minimumIntervalMS = 5
    static let maximumIntervalMS = 1_000
    static let path = "/Library/Application Support/SurgeDisconnectGuard/settings.json"
    static let publicPath = "/var/run/local.surgedisconnect.settings.json"
    let timeoutMS: Int
    /// Pause between two mode queries. Exit and proxy events never wait for it.
    let intervalMS: Int
    /// Restore the network by itself once Surge is healthy again after a lock.
    let autoRestore: Bool
    init(timeoutMS: Int = defaultTimeoutMS, intervalMS: Int = defaultIntervalMS, autoRestore: Bool = false) throws {
        guard (Self.minimumTimeoutMS...Self.maximumTimeoutMS).contains(timeoutMS) else {
            throw SettingsFailure("请输入 10～10000 ms 的整数。")
        }
        guard (Self.minimumIntervalMS...Self.maximumIntervalMS).contains(intervalMS) else {
            throw SettingsFailure("查询间隔请输入 5～1000 ms 的整数。")
        }
        self.timeoutMS = timeoutMS
        self.intervalMS = intervalMS
        self.autoRestore = autoRestore
    }
    enum CodingKeys: String, CodingKey { case timeoutMS, intervalMS, autoRestore }
    // Settings written by older versions only carry timeoutMS.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(timeoutMS: try values.decode(Int.self, forKey: .timeoutMS),
                      intervalMS: try values.decodeIfPresent(Int.self, forKey: .intervalMS) ?? Self.defaultIntervalMS,
                      autoRestore: try values.decodeIfPresent(Bool.self, forKey: .autoRestore) ?? false)
    }
    func with(timeoutMS: Int? = nil, intervalMS: Int? = nil, autoRestore: Bool? = nil) throws -> GuardSettings {
        try GuardSettings(timeoutMS: timeoutMS ?? self.timeoutMS, intervalMS: intervalMS ?? self.intervalMS,
                          autoRestore: autoRestore ?? self.autoRestore)
    }
    static func parse(_ text: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let ms = Int(value) else {
            throw SettingsFailure("请输入 10～10000 ms 的整数。")
        }
        return try GuardSettings(timeoutMS: ms).timeoutMS
    }
    static func parseInterval(_ text: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let ms = Int(value) else {
            throw SettingsFailure("查询间隔请输入 5～1000 ms 的整数。")
        }
        return try GuardSettings(intervalMS: ms).intervalMS
    }
    static func load(from path: String = path) throws -> GuardSettings {
        guard FileManager.default.fileExists(atPath: path) else { return try GuardSettings() }
        return try JSONDecoder().decode(GuardSettings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    func save(to path: String, permissions: Int = 0o600) throws {
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
    for broken in ["{\"timeoutMS\":0}", "{\"timeoutMS\":200,\"intervalMS\":4}", "{\"timeoutMS\":200,\"intervalMS\":1001}"] {
        try Data(broken.utf8).write(to: URL(fileURLWithPath: path))
        var rejected = false
        do { _ = try GuardSettings.load(from: path) } catch { rejected = true }
        guard rejected else { throw SettingsFailure("未拒绝损坏设置 \(broken)") }
    }
    try Data("{\"timeoutMS\":350}".utf8).write(to: URL(fileURLWithPath: path))
    let legacy = try GuardSettings.load(from: path)
    guard legacy.timeoutMS == 350, legacy.intervalMS == 20, !legacy.autoRestore else { throw SettingsFailure("旧版设置未按默认值补齐") }
    let changed = try legacy.with(intervalMS: 50, autoRestore: true)
    try changed.save(to: path)
    guard try GuardSettings.load(from: path) == changed, changed.timeoutMS == 350 else { throw SettingsFailure("修改单项设置时改动了其他项") }
    for input in ["", "4", "1001", "2.5", "20; whoami"] {
        var rejected = false
        do { _ = try GuardSettings.parseInterval(input) } catch { rejected = true }
        guard rejected else { throw SettingsFailure("未拒绝无效查询间隔") }
    }
    guard try GuardSettings.parseInterval(" 5 ") == 5, try GuardSettings.parseInterval("1000") == 1000 else { throw SettingsFailure("查询间隔解析错误") }
    print("PASS 默认 200ms/20ms、边界/自定义值、旧版设置兼容、单项修改、原子保存重读及非法输入/配置拒绝；仅临时目录。")
}
