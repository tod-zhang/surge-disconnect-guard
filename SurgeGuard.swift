import Foundation
import SystemConfiguration
import Darwin
import Dispatch

@_silgen_name("sg_set_up") func nativeSetUp(_ name: UnsafePointer<CChar>, _ up: Int32) -> Int32
@_silgen_name("sg_watch_exit") func watchExit(_ queue: Int32, _ pid: Int32) -> Int32
@_silgen_name("sg_wait_exit") func waitExit(_ queue: Int32, _ milliseconds: Int32) -> Int32
@_silgen_name("sg_process_uid") func processUID(_ pid: Int32) -> Int32
@_silgen_name("sg_fast_cutoff") func nativeFastCutoff(_ preferred: UnsafePointer<CChar>) -> Int32
@_silgen_name("sg_spawn") func nativeSpawn(_ path: UnsafePointer<CChar>,
    _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ output: UnsafeMutablePointer<Int32>, _ pid: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("sg_spawn_interactive") func nativeSpawnInteractive(_ path: UnsafePointer<CChar>,
    _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ output: UnsafeMutablePointer<Int32>, _ input: UnsafeMutablePointer<Int32>,
    _ pid: UnsafeMutablePointer<Int32>) -> Int32

let appExecutable = "/Applications/Surge.app/Contents/MacOS/Surge"
let surgeCLI = "/Applications/Surge.app/Contents/Applications/surge-cli"
let stateDirectory = "/Library/Application Support/SurgeDisconnectGuard"
let statePath = stateDirectory + "/locked.json"
let armedPath = stateDirectory + "/armed.json"
let processLockPath = stateDirectory + "/operation.lock"
let fm = FileManager.default
let logPath = "/var/log/surge-disconnect-guard.log"
let manualLockReason = "用户手动触发断网"
let featureTimeout: TimeInterval = Double(GuardSettings.defaultTimeoutMS) / 1000
let publicStatusPath = "/var/run/local.surgedisconnect.guard.status.json"

func publishStatus(_ phase: String, _ message: String, daemonPID: Int32 = 0, timeoutMS: Int? = nil) {
    guard geteuid() == 0 else { return }
    var value: [String: Any] = ["installed": true, "phase": phase, "message": message,
        "boot": fm.fileExists(atPath: stateDirectory + "/boot.enabled") ||
                fm.fileExists(atPath: "/Library/LaunchDaemons/local.surgedisconnect.guard.plist"),
        "updatedAt": Date().timeIntervalSince1970, "daemonPID": daemonPID, "version": buildVersion]
    if let timeoutMS = timeoutMS { value["timeoutMS"] = timeoutMS }
    do {
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: URL(fileURLWithPath: publicStatusPath), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicStatusPath)
    } catch { log("ERROR 无法发布界面状态：\(error)") }
}

struct GuardError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func log(_ text: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(text)")
    fflush(stdout)
}

/// launchd opens the log once; after newsyslog renames it, point stdout/stderr at the new file.
func reopenLogIfRotated() {
    var current = stat(), onDisk = stat()
    guard fstat(STDOUT_FILENO, &current) == 0, current.st_mode & S_IFMT == S_IFREG else { return }
    if stat(logPath, &onDisk) == 0 && onDisk.st_ino == current.st_ino && onDisk.st_dev == current.st_dev { return }
    let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return }
    fflush(stdout)
    dup2(fd, STDOUT_FILENO)
    dup2(fd, STDERR_FILENO)
    close(fd)
}

func isTunnel(_ name: String) -> Bool {
    name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")
}

struct Service: Codable, Equatable {
    var name: String
    var enabled: Bool
}
struct NetworkView {
    var services: [String: Service]
    var upInterfaces: Set<String>
    var wifi: [String: Bool]
    var allInterfaces: Set<String> = []
}
struct LockState: Codable, Equatable {
    var version = 1
    var reason: String
    var date = Date()
    var services: [String: Service] = [:]
    var interfaces: [String: Bool] = [:]
    var wifi: [String: Bool] = [:]

    // Add new devices without overwriting their saved pre-lock state.
    mutating func merge(_ view: NetworkView) {
        for (id, value) in view.services where services[id] == nil { services[id] = value }
        for name in view.allInterfaces.union(view.upInterfaces) where interfaces[name] == nil {
            interfaces[name] = view.upInterfaces.contains(name)
        }
        for (name, value) in view.wifi where wifi[name] == nil { wifi[name] = value }
    }
}

protocol NetworkAccess {
    func view(includeWiFiPower: Bool) throws -> NetworkView
    func interfaces() throws -> (all: Set<String>, up: Set<String>)
    func setInterfaces(_ names: Set<String>, up: Bool) -> [String]
    func setServices(_ values: [String: Service]) throws
    func setWiFi(_ values: [String: Bool]) -> [String]
    func emergencyCutoff() -> [String]
}

func interfaceState() throws -> (all: Set<String>, up: Set<String>) {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { throw GuardError("getifaddrs: \(errno)") }
    defer { freeifaddrs(head) }
    var all = Set<String>(), up = Set<String>()
    var ptr = head
    while let current = ptr {
        let item = current.pointee
        if item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
            let name = String(cString: item.ifa_name)
            all.insert(name)
            if item.ifa_flags & UInt32(IFF_UP) != 0 { up.insert(name) }
        }
        ptr = item.ifa_next
    }
    return (all, up)
}

struct CommandResult { let code: Int32; let text: String }
// Only fixed system binaries are called, with separate arguments and no shell.
func runCommand(_ executable: String, _ args: [String], timeout: TimeInterval = 4,
                cancel: (() -> Bool)? = nil) -> CommandResult {
    let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { $0.withCString { strdup($0) } } + [nil]
    let environmentStrings: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C"]
    let envp: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { $0.withCString { strdup($0) } } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var fd: Int32 = -1, pid: Int32 = 0
    let result = executable.withCString { path in
        argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { environment in
                nativeSpawn(path, arguments.baseAddress!, environment.baseAddress!, &fd, &pid)
            }
        }
    }
    guard result == 0 else { return CommandResult(code: -1, text: String(cString: strerror(result))) }
    defer { close(fd) }
    let end = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096), status: Int32 = 0
    func drain() {
        for _ in 0..<16 {
            let bytes = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if bytes <= 0 { break }
            // Drain even after reaching the cap to avoid a full pipe blocking the child.
            if data.count < 65_536 { data.append(contentsOf: buffer.prefix(min(bytes, 65_536 - data.count))) }
        }
    }
    while true {
        drain()
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid {
            drain()
            // Clean up a child that outlived a prematurely exiting wrapper.
            kill(-pid, SIGKILL)
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            return CommandResult(code: code, text: String(data: data, encoding: .utf8) ?? "")
        }
        if reaped < 0 && errno != EINTR {
            kill(-pid, SIGKILL)
            return CommandResult(code: -1, text: "waitpid failed: \(errno)")
        }
        let cancelled = cancel?() == true
        if cancelled || ProcessInfo.processInfo.systemUptime >= end {
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            return CommandResult(code: -1, text: cancelled ? "Surge process exited while checking features" : "command timed out")
        }
        usleep(1_000)
    }
}

func validateFeatures(_ response: CommandResult) throws {
    guard response.code == 0 else {
        throw GuardError("Surge 模式查询失败/超时：\(response.text.prefix(500))")
    }
    var values: [String: String] = [:]
    let required: Set<String> = ["enhanced-mode", "system-proxy"]
    for line in response.text.components(separatedBy: .newlines) {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let key = parts.first, required.contains(key) else { continue }
        guard parts.count == 2, values[key] == nil, ["On", "Off"].contains(parts[1]) else {
            throw GuardError("Surge 模式状态格式异常：\(key)")
        }
        values[key] = parts[1]
    }
    for key in required.sorted() {
        guard let value = values[key] else { throw GuardError("无法确认 Surge 模式状态：\(key)") }
        guard value == "On" else { throw GuardError("Surge 模式未开启：\(key)") }
    }
}

func requireHealthySurge(pids: Set<Int32>, cancel: (() -> Bool)? = nil) throws {
    guard !pids.isEmpty else { throw GuardError("Surge 未运行；请先打开 Surge 并同时开启增强模式和系统代理。") }
    var owners = Set<Int32>()
    for pid in pids {
        let uid = processUID(pid)
        guard uid >= 0 else { throw GuardError("无法确认 Surge 进程所属用户（进程可能已退出）") }
        owners.insert(uid)
    }
    for uid in owners.sorted() {
        let response: CommandResult
        if uid == Int32(geteuid()) {
            response = runCommand(surgeCLI, ["feature", "list"], timeout: 0.5, cancel: cancel)
        } else {
            guard geteuid() == 0 else { throw GuardError("无法查询其他用户的 Surge 状态") }
            // Enter Surge's bootstrap namespace and drop privileges before executing its CLI.
            response = runCommand("/bin/launchctl", ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H",
                                  "-u", "#\(uid)", surgeCLI, "feature", "list"], timeout: 0.5, cancel: cancel)
        }
        try validateFeatures(response)
    }
}

// The prompt terminates exactly one command response. No queries are pipelined,
// so a previous On response can never satisfy the next health check.
struct PromptFrames {
    var buffer = Data()
    mutating func append(_ data: Data) throws {
        guard buffer.count + data.count <= 65_536 else { throw GuardError("Surge CLI 响应过大") }
        buffer.append(data)
    }
    mutating func pop() -> String? {
        let delimiter = Data("\n> ".utf8)
        guard let range = buffer.range(of: delimiter) else { return nil }
        let frame = String(data: buffer[..<range.lowerBound], encoding: .utf8)
        buffer.removeSubrange(..<range.upperBound)
        return frame
    }
}

final class PersistentFeatures {
    var output: Int32 = -1
    var input: Int32 = -1
    var pid: Int32 = 0
    var frames = PromptFrames()
    let cancel: () -> Bool
    init(uid: Int32, cancel: @escaping () -> Bool,
         testCommand: (String, [String])? = nil) throws {
        self.cancel = cancel
        let executable: String
        let args: [String]
        if let command = testCommand { executable = command.0; args = command.1 }
        else if uid == Int32(geteuid()) { executable = surgeCLI; args = [] }
        else {
            guard geteuid() == 0 else { throw GuardError("无法以 Surge 用户身份建立持续连接") }
            executable = "/bin/launchctl"
            args = ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H", "-u", "#\(uid)", surgeCLI]
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { $0.withCString { strdup($0) } } + [nil]
        let strings = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C"]
        let envp: [UnsafeMutablePointer<CChar>?] = strings.map { $0.withCString { strdup($0) } } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let result = executable.withCString { path in
            argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
                nativeSpawnInteractive(path, a.baseAddress!, e.baseAddress!, &output, &input, &pid)
            } }
        }
        guard result == 0 else { throw GuardError("无法建立 Surge 持续连接：\(result)") }
        do { _ = try readFrame(timeout: 0.5) } catch { closeSession(); throw error }
    }
    func closeSession() {
        if input >= 0 { close(input); input = -1 }
        if output >= 0 { close(output); output = -1 }
        if pid > 0 {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            pid = 0
        }
    }
    deinit { closeSession() }
    func readFrame(timeout: TimeInterval) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            guard !cancel() else { throw GuardError("持续查询已取消") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GuardError("持续查询超时（\(Int(timeout * 1000))ms）") }
            if let frame = frames.pop() { return frame }
            let n = bytes.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
            if n > 0 { try frames.append(Data(bytes.prefix(n))); continue }
            if n == 0 { throw GuardError("Surge 持续查询连接已断开") }
            guard errno == EAGAIN || errno == EINTR else { throw GuardError("持续查询读取失败：\(errno)") }
            // Sleep in the kernel until the reply arrives instead of waking every few hundred
            // microseconds. The 50ms cap keeps cancellation responsive.
            let remaining = (deadline - ProcessInfo.processInfo.systemUptime) * 1000
            var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, Int32(min(max(remaining.rounded(.up), 1), 50)))
        }
    }
    func query(timeout: TimeInterval = featureTimeout) throws {
        guard frames.buffer.isEmpty else { throw GuardError("Surge CLI 存在未归属的残余响应") }
        let command = Array("feature list\n".utf8)
        let count = command.withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
        guard count == command.count else { throw GuardError("无法发送 Surge 模式查询：\(errno)") }
        let text = try readFrame(timeout: timeout)
        try validateFeatures(CommandResult(code: 0, text: text))
    }
}

final class FeatureMonitor {
    let gate: FastGate
    let mutex = NSLock()
    let sleep = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    var stopped = false
    var ready = false
    init(gate: FastGate, pids: Set<Int32>, timeoutMS: Int = GuardSettings.defaultTimeoutMS,
         intervalMS: Int = GuardSettings.defaultIntervalMS, testCommand: (String, [String])? = nil) throws {
        let settings = try GuardSettings(timeoutMS: timeoutMS, intervalMS: intervalMS)
        self.gate = gate
        var owners = Set<Int32>()
        for pid in pids {
            let uid = processUID(pid)
            guard uid >= 0 else { throw GuardError("无法确认 Surge 用户") }
            owners.insert(uid)
        }
        guard !owners.isEmpty else { throw GuardError("Surge 未运行") }
        DispatchQueue(label: "SurgeGuard.PersistentQueries", qos: .userInteractive).async { [self] in
            defer { finished.signal() }
            var sessions: [PersistentFeatures] = []
            do {
                for uid in owners.sorted() {
                    sessions.append(try PersistentFeatures(uid: uid, cancel: { self.isStopped || self.gate.trip != nil },
                                                           testCommand: testCommand))
                }
                while !isStopped && gate.trip == nil {
                    for session in sessions { try session.query(timeout: Double(settings.timeoutMS) / 1000) }
                    mutex.lock(); ready = true; mutex.unlock()
                    _ = sleep.wait(timeout: .now() + .milliseconds(settings.intervalMS))
                }
            } catch {
                if !isStopped { gate.trigger("Surge 持续模式检查失败：\(error)") }
            }
            // Cut interfaces before terminating/reaping a failed CLI session.
            sessions.removeAll()
        }
    }
    var isReady: Bool { mutex.lock(); defer { mutex.unlock() }; return ready }
    var isStopped: Bool { mutex.lock(); defer { mutex.unlock() }; return stopped }
    func stop() { mutex.lock(); stopped = true; mutex.unlock(); sleep.signal() }
}

final class MacNetwork: NetworkAccess {
    private let priorityLock = NSLock()
    private var preferredInterface = ""
    func preferences() throws -> SCPreferences {
        guard let prefs = SCPreferencesCreate(nil, "SurgeDisconnectGuard" as CFString, nil) else {
            throw GuardError("无法读取网络配置：\(SCError())")
        }
        return prefs
    }
    func view(includeWiFiPower: Bool = true) throws -> NetworkView {
        let prefs = try preferences()
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            throw GuardError("无法枚举网络服务：\(SCError())")
        }
        var values: [String: Service] = [:]
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            values[id] = Service(name: SCNetworkServiceGetName(service) as String? ?? id,
                                 enabled: SCNetworkServiceGetEnabled(service))
        }
        let flags = try interfaceState()
        if let route = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let primary = route["PrimaryInterface"] as? String {
            priorityLock.lock(); preferredInterface = primary; priorityLock.unlock()
        }
        var wifi: [String: Bool] = [:]
        if includeWiFiPower {
            let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
            for interface in interfaces where SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211 {
                guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                wifi[name] = try wifiPower(name)
            }
        }
        return NetworkView(services: values, upInterfaces: flags.up, wifi: wifi, allInterfaces: flags.all)
    }
    /// Read from the configd store, which costs no process; snapshots run every second.
    /// networksetup stays as the fallback when the store has no power entry.
    func wifiPower(_ name: String) throws -> Bool {
        if let state = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/AirPort" as CFString) as? [String: Any],
           let power = state["Power Status"] as? NSNumber {
            return power.boolValue
        }
        let result = runCommand("/usr/sbin/networksetup", ["-getairportpower", name])
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.code == 0, text.hasSuffix(": On") || text.hasSuffix(": Off") else {
            throw GuardError("无法读取 Wi-Fi 电源：\(name) \(result.text)")
        }
        return text.hasSuffix(": On")
    }
    func interfaces() throws -> (all: Set<String>, up: Set<String>) { try interfaceState() }
    func setInterfaces(_ names: Set<String>, up: Bool) -> [String] {
        var errors: [String] = []
        for name in names.sorted() where name != "lo0" {
            let result = name.withCString { nativeSetUp($0, up ? 1 : 0) }
            // Disappearing VPN and unplugged adapters are expected.
            if result != 0 && result != ENXIO && result != ENODEV {
                errors.append("网卡 \(name) \(up ? "开启" : "关闭")失败：\(String(cString: strerror(result)))")
            }
        }
        return errors
    }
    func setServices(_ values: [String: Service]) throws {
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, false) else { throw GuardError("网络配置被占用：\(SCError())") }
        defer { SCPreferencesUnlock(prefs) }
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            throw GuardError("无法枚举网络服务")
        }
        var changed = false
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            guard let desired = values[id], SCNetworkServiceGetEnabled(service) != desired.enabled else { continue }
            guard SCNetworkServiceSetEnabled(service, desired.enabled) else {
                throw GuardError("更改服务 \(desired.name) 失败：\(SCError())")
            }
            changed = true
        }
        if changed {
            guard SCPreferencesCommitChanges(prefs) else { throw GuardError("保存网络配置失败：\(SCError())") }
            guard SCPreferencesApplyChanges(prefs) else { throw GuardError("应用网络配置失败：\(SCError())") }
        }
    }
    func setWiFi(_ values: [String: Bool]) -> [String] {
        var errors: [String] = []
        for (device, enabled) in values {
            let result = runCommand("/usr/sbin/networksetup", ["-setairportpower", device, enabled ? "on" : "off"])
            if result.code != 0 { errors.append("Wi-Fi \(device)：\(result.text)") }
        }
        return errors
    }
    func emergencyCutoff() -> [String] {
        priorityLock.lock(); let preferred = preferredInterface; priorityLock.unlock()
        let errors = preferred.withCString { nativeFastCutoff($0) }
        return errors == 0 ? [] : ["快速关闭网卡遇到 \(errors) 项错误；将继续重试"]
    }
}

protocol StateStore {
    func load() throws -> LockState?
    func save(_ state: LockState) throws
    func savePrepared(_ state: LockState) throws
    func clear() throws
}
final class DiskStore: StateStore {
    func load() throws -> LockState? {
        // An interrupted armed run is fail-closed, including a crash after the
        // fast cutoff but before locked.json could be written.
        let path = fm.fileExists(atPath: statePath) ? statePath : armedPath
        guard fm.fileExists(atPath: path) else { return nil }
        let state = try JSONDecoder().decode(LockState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard state.version == 1 else { throw GuardError("不支持的状态文件版本；保持断网，未覆盖备份") }
        return state
    }
    func save(_ state: LockState) throws {
        try write(state, to: statePath)
    }
    func savePrepared(_ state: LockState) throws { try write(state, to: armedPath) }
    func write(_ state: LockState, to path: String) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let fd = open(path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
    func clear() throws {
        for path in [statePath, armedPath] where fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
    }
}

struct FastTrip {
    let reason: String
    let errors: [String]
    let flags: (all: Set<String>, up: Set<String>)?
    let milliseconds: Double
    let enteredAtNanoseconds: UInt64
}

// Only memory operations and the native interface cutoff occur inside trigger.
// The main thread persists the lock and logs after the callback has cut interfaces.
final class FastGate {
    let mutex = NSLock()
    let wakeup = DispatchSemaphore(value: 0)
    let cutoff: () -> [String]
    let capture: () -> (all: Set<String>, up: Set<String>)?
    private var value: FastTrip?
    init(cutoff: @escaping () -> [String],
         capture: @escaping () -> (all: Set<String>, up: Set<String>)? = { try? interfaceState() }) {
        self.cutoff = cutoff; self.capture = capture
    }
    func trigger(_ reason: String) {
        mutex.lock()
        guard value == nil else { mutex.unlock(); return }
        let start = DispatchTime.now().uptimeNanoseconds
        let flags = capture()
        let errors = cutoff()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        value = FastTrip(reason: reason, errors: errors, flags: flags, milliseconds: elapsed,
                         enteredAtNanoseconds: start)
        mutex.unlock()
        wakeup.signal()
    }
    var trip: FastTrip? {
        mutex.lock(); defer { mutex.unlock() }; return value
    }
}

struct ProxySignature: Equatable {
    let httpHost: String
    let httpPort: Int
    let httpsHost: String
    let httpsPort: Int
    static func read() -> ProxySignature? {
        guard let values = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return nil }
        return parse(values)
    }
    static func parse(_ values: [String: Any]) -> ProxySignature? {
        guard
              (values["HTTPEnable"] as? NSNumber)?.boolValue == true,
              (values["HTTPSEnable"] as? NSNumber)?.boolValue == true,
              let httpHost = values["HTTPProxy"] as? String,
              let httpsHost = values["HTTPSProxy"] as? String,
              let httpPort = values["HTTPPort"] as? Int, httpPort > 0,
              let httpsPort = values["HTTPSPort"] as? Int, httpsPort > 0,
              ["127.0.0.1", "::1", "localhost"].contains(httpHost),
              ["127.0.0.1", "::1", "localhost"].contains(httpsHost) else { return nil }
        return ProxySignature(httpHost: httpHost, httpPort: httpPort, httpsHost: httpsHost, httpsPort: httpsPort)
    }
}

final class ProxyWatchContext {
    let gate: FastGate
    let expected: ProxySignature
    init(gate: FastGate, expected: ProxySignature) { self.gate = gate; self.expected = expected }
}

final class ProxyObserver {
    var store: SCDynamicStore?
    init(gate: FastGate, queue: DispatchQueue) throws {
        guard let expected = ProxySignature.read() else { throw GuardError("无法确认本机 HTTP/HTTPS 系统代理同时指向回环地址") }
        let box = ProxyWatchContext(gate: gate, expected: expected)
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                _ = Unmanaged<ProxyWatchContext>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                Unmanaged<ProxyWatchContext>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "SurgeDisconnectGuard.ProxyWatch" as CFString, { _, _, context in
            guard let context = context else { return }
            let observer = Unmanaged<ProxyWatchContext>.fromOpaque(context).takeUnretainedValue()
            if ProxySignature.read() != observer.expected { observer.gate.trigger("系统代理有效配置已关闭、改变或无法确认") }
        }, &context)
        guard let store = store,
              SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/Proxies"] as CFArray,
                ["State:/Network/Service/.*/Proxies", "Setup:/Network/Service/.*/Proxies"] as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            throw GuardError("无法订阅系统代理配置通知")
        }
        // Close the read/subscribe race without changing any configuration.
        if ProxySignature.read() != expected { gate.trigger("系统代理配置在监听初始化期间发生变化") }
    }
    deinit { if let store = store { SCDynamicStoreSetDispatchQueue(store, nil) } }
}

final class GuardEngine {
    let network: NetworkAccess
    let store: StateStore
    var state: LockState?
    var prepared: LockState?
    var corrupted = false
    var lastWiFiCheck = Date.distantPast
    var lastError = ""
    var lastErrorDate = Date.distantPast
    /// With auto-restore on, leave tunnel interfaces alone while locked: they carry nothing once
    /// physical interfaces and services are off, and Surge's own tunnel must survive to recover.
    var spareTunnels = false
    // Preference reads and locks are throttled; interface ioctls stay on every tick.
    static let fullEnforceInterval: TimeInterval = 0.1
    var lastFullEnforce: TimeInterval = -.infinity
    init(network: NetworkAccess, store: StateStore) {
        self.network = network; self.store = store
        do { state = try store.load() } catch {
            corrupted = true
            log("ERROR 状态文件不可读，按断网处理：\(error)")
        }
    }
    var locked: Bool { state != nil || corrupted }
    func cuttable(_ names: Set<String>) -> Set<String> { spareTunnels ? names.filter { !isTunnel($0) } : names }
    func report(_ messages: [String]) {
        let message = messages.joined(separator: "; ")
        if !message.isEmpty && (message != lastError || Date().timeIntervalSince(lastErrorDate) > 30) {
            log("ERROR \(message)"); lastError = message; lastErrorDate = Date()
        }
    }
    func prepare(ifHealthy: () -> Bool = { true }) throws {
        guard !locked else { return }
        let view = try network.view(includeWiFiPower: true)
        var snapshot = LockState(reason: "预备恢复快照；守护中断后按锁定处理")
        snapshot.merge(view)
        guard ifHealthy() else { return }
        // An unchanged snapshot is already durable on disk; skip the rewrite and fsync.
        if let old = prepared, old.services == snapshot.services,
           old.interfaces == snapshot.interfaces, old.wifi == snapshot.wifi { return }
        try store.savePrepared(snapshot)
        prepared = snapshot
    }
    func lock(_ reason: String, fast: FastTrip? = nil) {
        if !locked {
            // Normal arming prepares this ahead of time; standalone/manual lock
            // also preserves a recovery snapshot before its first mutation.
            if prepared == nil && fast == nil { do { try prepare() } catch { report(["准备恢复快照失败：\(error)"]) } }
            let errors = fast?.errors ?? network.emergencyCutoff()
            state = prepared ?? LockState(reason: reason)
            state?.reason = reason
            if let flags = fast?.flags {
                for name in flags.all { state?.interfaces[name] = flags.up.contains(name) }
            }
            do { if let saved = state { try store.save(saved) } } catch { report(["保存断网标记失败：\(error)"]) }
            log("LOCKED \(reason)")
            if let fast = fast { log(String(format: "FAST 快速路径调用耗时 %.3f ms（不等于实测断网生效时间）", fast.milliseconds)) }
            report(errors)
        }
        enforce()
    }
    // Called about every 10 ms while locked. Newly seen interfaces are saved before
    // their first mutation; services and Wi-Fi go through the throttled full pass.
    func enforceTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFullEnforce >= Self.fullEnforceInterval { enforce(); return }
        var errors: [String] = []
        do {
            let flags = try network.interfaces()
            if !corrupted, var saved = state {
                let before = saved
                for name in flags.all.union(flags.up) where saved.interfaces[name] == nil {
                    saved.interfaces[name] = flags.up.contains(name)
                }
                if before != saved {
                    do { try store.save(saved) } catch { errors.append("\(error)") }
                    state = saved
                }
            }
            errors += network.setInterfaces(cuttable(flags.up), up: false)
        } catch {
            errors.append("\(error)")
            errors += network.emergencyCutoff()
        }
        report(errors)
    }
    func enforce() {
        lastFullEnforce = ProcessInfo.processInfo.systemUptime
        var errors: [String] = []
        do {
            // Save before each first mutation of a newly seen interface or service.
            // First capture includes Wi-Fi power before disabling services/interfaces.
            let needsWiFi = state?.wifi.isEmpty == true && lastWiFiCheck == .distantPast
            let quick = try network.view(includeWiFiPower: needsWiFi)
            if !corrupted, var saved = state {
                let before = saved
                saved.merge(quick)
                if before != saved || !(store is DiskStore) || !fm.fileExists(atPath: statePath) {
                    try store.save(saved)
                }
                state = saved
            }
            // Fast native ioctl closes currently UP interfaces before slower preference operations.
            errors += network.setInterfaces(cuttable(quick.upInterfaces), up: false)
            // Lock the system preferences only when some service still needs disabling.
            let disabled = quick.services.filter { $0.value.enabled }.mapValues { Service(name: $0.name, enabled: false) }
            if !disabled.isEmpty {
                do { try network.setServices(disabled) } catch { errors.append("\(error)") }
            }

            if Date().timeIntervalSince(lastWiFiCheck) >= 2 {
                lastWiFiCheck = Date()
                do {
                    let full = try network.view(includeWiFiPower: true)
                    if !corrupted, var saved = state {
                        saved.merge(full)
                        try store.save(saved)
                        state = saved
                    }
                    errors += network.setWiFi(full.wifi.filter { $0.value }.mapValues { _ in false })
                    errors += network.setInterfaces(cuttable(full.upInterfaces), up: false)
                } catch { errors.append("\(error)") }
            }
        } catch {
            errors.append("\(error)")
            // Persistence/configuration errors must never prevent best-effort cutoff.
            errors += network.emergencyCutoff()
            if let view = try? network.view(includeWiFiPower: false) {
                errors += network.setInterfaces(view.upInterfaces, up: false)
                do { try network.setServices(view.services.mapValues { Service(name: $0.name, enabled: false) }) }
                catch { errors.append("\(error)") }
            }
        }
        report(errors)
    }
    /// raiseTunnels is used by auto-restore only: it also raises tunnels that were up before the
    /// lock and still exist, so a Surge that stayed running gets its tunnel back.
    func restore(raiseTunnels: Bool = false) throws {
        if corrupted { throw GuardError("备份不可读，不能自动恢复。请查看说明中的应急恢复步骤。") }
        guard let saved = state else { log("没有断网备份；网络配置未改动。"); return }
        // Restore services by stable UUID, including originally disabled services.
        try network.setServices(saved.services)
        let wifiErrors = network.setWiFi(saved.wifi)
        // Virtual interfaces are recreated by their owning app; never raise stale utun names.
        var raised = Set(saved.interfaces.filter { $0.value }.keys.filter {
            !$0.hasPrefix("utun") && !$0.hasPrefix("ppp") && $0 != "lo0"
        })
        if raiseTunnels, let present = try? network.interfaces().all {
            raised.formUnion(saved.interfaces.filter { $0.value && isTunnel($0.key) && present.contains($0.key) }.keys)
        }
        let interfaceErrors = network.setInterfaces(raised, up: true)
        guard wifiErrors.isEmpty && interfaceErrors.isEmpty else {
            throw GuardError((wifiErrors + interfaceErrors).joined(separator: "; "))
        }
        try store.clear()
        state = nil
        // The cleared snapshot must be written again on the next arm, not skipped as unchanged.
        prepared = nil
        log("RESTORED 已恢复断网前的网络服务、Wi-Fi 电源和网卡状态。VPN 可能需要重新连接。")
    }
}

func surgePIDs(includeComponents: Bool = false) throws -> Set<Int32> {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { throw GuardError("无法枚举进程") }
    var pids = [Int32](repeating: 0, count: Int(count) + 1024)
    let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
    let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
    guard actual > 0 && actual < pids.count else { throw GuardError("进程枚举失败或列表溢出") }
    var matches = Set<Int32>()
    for pid in pids.prefix(Int(actual)) where pid > 0 {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN in the macOS SDK.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = UInt32(path.count)
        let result = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, size) }
        if result > 0 {
            let name = String(cString: path)
            let component = name == "/Library/PrivilegedHelperTools/com.nssurge.surge-mac.helper" ||
                (name.hasPrefix("/Library/SystemExtensions/") && name.hasSuffix(".systemextension/Contents/MacOS/com.nssurge.surge-mac.ne"))
            if name == appExecutable || (includeComponents && component) { matches.insert(pid) }
        }
    }
    return matches
}

func requireRoot() throws {
    guard geteuid() == 0 else { throw GuardError("此操作需要管理员权限。请运行配套 .command 文件。") }
}
func acquireLock(wait: Bool = false) throws -> Int32 {
    let fd = open(processLockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw GuardError("无法打开操作锁：\(errno)") }
    let deadline = Date().addingTimeInterval(wait ? 5 : 0)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard wait && Date() < deadline else {
            close(fd); throw GuardError("守护进程或恢复操作仍在运行；请先停止守护。")
        }
        usleep(50_000)
    }
    return fd
}

/// Checks off the main loop whether Surge is healthy again, so a lock keeps enforcing meanwhile.
final class RecoveryProbe {
    private let queue = DispatchQueue(label: "SurgeGuard.RecoveryProbe", qos: .utility)
    private let mutex = NSLock()
    private var running = false
    private var healthy = 0
    let check: () -> Bool
    init(check: @escaping () -> Bool = {
        guard let pids = try? surgePIDs(), !pids.isEmpty else { return false }
        do { try requireHealthySurge(pids: pids); return true } catch { return false }
    }) { self.check = check }
    /// Consecutive healthy checks so far; starts the next check when none is running.
    func poll() -> Int {
        mutex.lock(); defer { mutex.unlock() }
        if !running {
            running = true
            queue.async { [self] in
                let ok = check()
                mutex.lock(); healthy = ok ? healthy + 1 : 0; running = false; mutex.unlock()
            }
        }
        return healthy
    }
    func reset() { mutex.lock(); healthy = 0; mutex.unlock() }
    var streak: Int { mutex.lock(); defer { mutex.unlock() }; return healthy }
    /// Tests only: wait for the check in flight.
    func settle() { queue.sync {} }
}

func daemon() throws {
    try requireRoot()
    let fd = try acquireLock()
    defer { close(fd) }
    let network = MacNetwork()
    let engine = GuardEngine(network: network, store: DiskStore())
    // A gate trips only once; auto-restore re-arms with a fresh one. Callbacks capture the
    // gate they were armed with, never this variable.
    var gate = FastGate(cutoff: { network.emergencyCutoff() })
    // Separate queues keep a slow preference query off the process-exit callback.
    let exitQueue = DispatchQueue(label: "SurgeGuard.ProcessExit", qos: .userInteractive, attributes: .concurrent)
    let proxyQueue = DispatchQueue(label: "SurgeGuard.ProxyChanges", qos: .userInteractive)
    var sources: [Int32: DispatchSourceProcess] = [:]
    var proxyObserver: ProxyObserver?
    var featureMonitor: FeatureMonitor?
    var loggedReady = false
    // Set after an auto-restore until the system proxy is confirmed and observed again.
    var proxyDeadline: TimeInterval?
    func disarm() {
        featureMonitor?.stop(); featureMonitor = nil
        sources.values.forEach { $0.cancel() }; sources = [:]
        proxyObserver = nil; loggedReady = false; proxyDeadline = nil
    }
    defer { disarm() }
    func watch(_ pids: Set<Int32>, _ current: FastGate) {
        for pid in pids.subtracting(Set(sources.keys)) {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: exitQueue)
            source.setEventHandler { current.trigger("收到 Surge 主进程/后台组件退出事件，PID \(pid)") }
            source.activate()
            sources[pid] = source
            log("ARMED 事件监听 Surge PID \(pid)")
        }
    }
    var nextSnapshot: TimeInterval = 0
    var settings = try GuardSettings()
    var autoRestore = false
    var lastPublished: TimeInterval = 0
    var nextSettingsRead: TimeInterval = 0
    var nextLogCheck: TimeInterval = 0
    var nextProbe: TimeInterval = 0
    let probe = RecoveryProbe()
    if !engine.locked {
        do { try engine.prepare(); nextSnapshot = ProcessInfo.processInfo.systemUptime + 1 }
        catch { gate.trigger("无法准备恢复快照：\(error)") }
    } else {
        engine.report(network.emergencyCutoff())
    }
    do { settings = try GuardSettings.load(); autoRestore = settings.autoRestore }
    catch { gate.trigger("无法读取守护设置：\(error)") }
    log("START \(buildVersion) 持续连接；正常查询后间隔 \(settings.intervalMS)ms、单次查询超时 \(settings.timeoutMS)ms；首次连接最多等待 500ms；自动恢复网络\(autoRestore ? "已开启" : "已关闭")。")
    while true {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextLogCheck { reopenLogIfRotated(); nextLogCheck = now + 30 }
        if now >= nextSettingsRead {
            // The auto-restore switch applies immediately; timeout and interval wait for the next start.
            nextSettingsRead = now + 1
            if let saved = try? GuardSettings.load() { autoRestore = saved.autoRestore }
            engine.spareTunnels = autoRestore && !engine.corrupted && engine.state?.reason != manualLockReason
        }
        if let trip = gate.trip, !engine.locked { engine.lock(trip.reason, fast: trip) }
        if engine.locked {
            // A manual lock or an unreadable backup never restores by itself.
            let recoverable = engine.spareTunnels
            if !recoverable { probe.reset() }
            else if now >= nextProbe {
                nextProbe = now + 1
                if probe.poll() >= 3 {
                    probe.reset()
                    // Arm completely while still locked, then restore: a failure at any step stays cut off.
                    disarm()
                    let fresh = FastGate(cutoff: { network.emergencyCutoff() })
                    gate = fresh
                    do {
                        let pids = try surgePIDs()
                        guard !pids.isEmpty else { throw GuardError("Surge 未运行") }
                        watch(try surgePIDs(includeComponents: true), fresh)
                        let monitor = try FeatureMonitor(gate: fresh, pids: pids, timeoutMS: settings.timeoutMS,
                                                         intervalMS: settings.intervalMS)
                        featureMonitor = monitor
                        let deadline = ProcessInfo.processInfo.systemUptime + 2
                        while !monitor.isReady && fresh.trip == nil && ProcessInfo.processInfo.systemUptime < deadline {
                            engine.enforceTick()
                            usleep(10_000)
                        }
                        guard monitor.isReady, fresh.trip == nil else {
                            throw GuardError(fresh.trip?.reason ?? "Surge 持续查询未在 2 秒内就绪")
                        }
                        // A process that exited before its source was registered would never fire.
                        guard Set(sources.keys).isSubset(of: try surgePIDs(includeComponents: true)) else {
                            throw GuardError("Surge 进程在布防期间退出")
                        }
                        try engine.restore(raiseTunnels: true)
                        log("AUTO-RESTORED Surge 双模式连续 3 次确认正常，已自动恢复网络；确认系统代理后完成布防。")
                        proxyDeadline = ProcessInfo.processInfo.systemUptime + 15
                        nextSnapshot = 0
                        lastPublished = 0
                    } catch {
                        log("自动恢复未完成，保持断网，30 秒后再试：\(error)")
                        disarm()
                        if engine.locked { engine.enforce() }
                        nextProbe = ProcessInfo.processInfo.systemUptime + 30
                    }
                }
            }
            if engine.locked {
                if ProcessInfo.processInfo.systemUptime - lastPublished >= 1 {
                    var reason = engine.state?.reason ?? "恢复备份不可读，已按异常处理"
                    if recoverable { reason += "。Surge 恢复正常后将自动恢复网络。" }
                    publishStatus("locked", reason, daemonPID: getpid(), timeoutMS: settings.timeoutMS)
                    lastPublished = ProcessInfo.processInfo.systemUptime
                }
                engine.enforceTick()
                usleep(10_000)
                continue
            }
        }
        let current = gate
        do {
            let pids = try surgePIDs()
            if pids.isEmpty {
                current.trigger("未发现 Surge 主进程（退出、崩溃或尚未启动）")
                continue
            }
            let runtime = try surgePIDs(includeComponents: true)
            if !Set(sources.keys).isSubset(of: runtime) {
                current.trigger("被监控的 Surge 主进程或后台组件已消失")
                continue
            }
            watch(runtime, current)
            if current.trip != nil { continue }
            if featureMonitor == nil {
                try requireHealthySurge(pids: pids, cancel: { current.trip != nil })
                proxyObserver = try ProxyObserver(gate: current, queue: proxyQueue)
                featureMonitor = try FeatureMonitor(gate: current, pids: pids, timeoutMS: settings.timeoutMS,
                                                    intervalMS: settings.intervalMS)
            } else if proxyObserver == nil, let deadline = proxyDeadline {
                // Services were just re-enabled; the system proxy appears once they come up.
                if ProxySignature.read() != nil {
                    proxyObserver = try ProxyObserver(gate: current, queue: proxyQueue)
                    proxyDeadline = nil
                    log("REARMED 系统代理已确认，自动恢复后已完整布防。")
                } else if ProcessInfo.processInfo.systemUptime >= deadline {
                    current.trigger("自动恢复网络后 15 秒内系统代理仍未生效")
                    continue
                }
            }
            if featureMonitor?.isReady == true && !loggedReady {
                loggedReady = true
                log("HEALTHY 持续查询已就绪；查询队列与快照写盘、进程检查独立。")
            }
            let armed = loggedReady && proxyObserver != nil
            if ProcessInfo.processInfo.systemUptime - lastPublished >= 1 {
                let message = armed ? "增强模式与系统代理已确认开启，持续检查中。" :
                    proxyDeadline != nil ? "网络已自动恢复，正在确认系统代理。" : "正在连接 Surge 并确认双模式状态。"
                publishStatus(armed ? "protecting" : "starting", message, daemonPID: getpid(), timeoutMS: settings.timeoutMS)
                lastPublished = ProcessInfo.processInfo.systemUptime
            }
            if current.trip == nil && ProcessInfo.processInfo.systemUptime >= nextSnapshot {
                try engine.prepare(ifHealthy: { current.trip == nil })
                nextSnapshot = ProcessInfo.processInfo.systemUptime + 1
            }
            _ = current.wakeup.wait(timeout: .now() + .milliseconds(100))
        } catch { current.trigger("Surge 运行状态检查失败：\(error)") }
    }
}

// Tests use in-memory networking only; no privileged/network mutation is called.
final class MemoryNetwork: NetworkAccess {
    var current = NetworkView(services: ["on": Service(name: "Wi-Fi", enabled: true),
                                        "off": Service(name: "Disabled VPN", enabled: false)],
                              upInterfaces: ["en0", "utun88"], wifi: ["en0": true],
                              allInterfaces: ["en0", "en2", "utun88"])
    var serviceFailure = false
    var mutations = 0
    var serviceCalls = 0
    var onCutoff: (() -> Void)?
    func view(includeWiFiPower: Bool) throws -> NetworkView {
        NetworkView(services: current.services, upInterfaces: current.upInterfaces,
                    wifi: includeWiFiPower ? current.wifi : [:], allInterfaces: current.allInterfaces)
    }
    func interfaces() throws -> (all: Set<String>, up: Set<String>) { (current.allInterfaces, current.upInterfaces) }
    func setInterfaces(_ names: Set<String>, up: Bool) -> [String] {
        mutations += 1
        if up { current.upInterfaces.formUnion(names) } else { current.upInterfaces.subtract(names) }
        return []
    }
    func setServices(_ values: [String: Service]) throws {
        serviceCalls += 1
        if serviceFailure { throw GuardError("injected preference failure") }
        mutations += 1
        for (id, value) in values { current.services[id] = value }
    }
    func setWiFi(_ values: [String: Bool]) -> [String] {
        mutations += 1
        for (id, value) in values { current.wifi[id] = value }
        return []
    }
    func emergencyCutoff() -> [String] {
        onCutoff?()
        return setInterfaces(current.upInterfaces, up: false)
    }
}
final class MemoryStore: StateStore {
    var value: LockState?
    var preparedValue: LockState?
    var fail = false
    var unreadable = false
    var onSave: (() -> Void)?
    func load() throws -> LockState? {
        if unreadable { throw GuardError("injected corrupt state") }; return value ?? preparedValue
    }
    func save(_ state: LockState) throws {
        onSave?()
        if fail { throw GuardError("injected disk error") }; value = state
    }
    func savePrepared(_ state: LockState) throws {
        if fail { throw GuardError("injected disk error") }; preparedValue = state
    }
    func clear() throws { value = nil; preparedValue = nil }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GuardError("TEST FAILED: \(message)") }
    print("PASS \(message)")
}
func selfTest() throws {
    try settingsSelfTest()
    var framing = PromptFrames()
    try framing.append(Data("Features:\n  enhanced-mode: On\n  system-proxy: On\n>".utf8))
    try expect(framing.pop() == nil, "提示符不完整时不接受旧状态")
    try framing.append(Data(" ".utf8))
    try expect(framing.pop()?.contains("system-proxy: On") == true && framing.buffer.isEmpty,
               "持续查询按完整响应分帧，消费后不残留旧状态")
    do {
        let simulated = try PersistentFeatures(uid: Int32(geteuid()), cancel: { false }, testCommand:
            ("/bin/sh", ["-c", "printf 'ready\\n> '; while IFS= read -r command; do printf 'enhanced-mode: Off\\nsystem-proxy: On\\n> '; done"]))
        var rejected = false
        do { try simulated.query() } catch { rejected = true }
        try expect(rejected, "真实管道中的关闭状态会被拒绝")
    }
    do {
        let simulated = try PersistentFeatures(uid: Int32(geteuid()), cancel: { false }, testCommand:
            ("/bin/sh", ["-c", "printf 'ready\\n> '; while IFS= read -r command; do /bin/sleep 10; done"]))
        var rejected = false
        do { try simulated.query(timeout: 0.02) } catch { rejected = String(describing: error).contains("超时") }
        try expect(rejected, "持续连接失去响应会按指定阈值超时")
    }
    do {
        // Launch /bin/sleep once untimed: its first launch on a fresh machine (e.g. a CI runner) can take
        // longer than the whole 200ms budget, which would test process startup rather than the threshold.
        let warmup = Process()
        warmup.executableURL = URL(fileURLWithPath: "/bin/sleep")
        warmup.arguments = ["0"]
        try warmup.run()
        warmup.waitUntilExit()
        let simulated = try PersistentFeatures(uid: Int32(geteuid()), cancel: { false }, testCommand:
            ("/bin/sh", ["-c", "printf 'ready\\n> '; while IFS= read -r command; do /bin/sleep 0.1; printf 'enhanced-mode: On\\nsystem-proxy: On\\n> '; done"]))
        try simulated.query()
        try expect(true, "100ms 短暂查询延迟在 200ms 阈值内被接受")
    }
    do {
        let simulated = try PersistentFeatures(uid: Int32(geteuid()), cancel: { false }, testCommand:
            ("/bin/sh", ["-c", "printf 'ready\\n> '; exit 0"]))
        var rejected = false
        do { try simulated.query() } catch { rejected = true }
        try expect(rejected, "持续连接退出能安全报错，不会因 SIGPIPE 终止守护")
    }
    for (index, script) in [
        "printf 'ready\\n> '; while IFS= read -r command; do printf 'enhanced-mode: Off\\nsystem-proxy: On\\n> '; done",
        "printf 'ready\\n> '; while IFS= read -r command; do /bin/sleep 10; done"
    ].enumerated() {
        let simulatedNetwork = MemoryNetwork()
        let gate = FastGate(cutoff: { simulatedNetwork.emergencyCutoff() }, capture: { nil })
        let monitor = try FeatureMonitor(gate: gate, pids: [getpid()], testCommand: ("/bin/sh", ["-c", script]))
        let triggered = gate.wakeup.wait(timeout: .now() + 2) == .success
        monitor.stop()
        let cleaned = monitor.finished.wait(timeout: .now() + 2) == .success
        try expect(triggered && simulatedNetwork.current.upInterfaces.isEmpty && cleaned,
                   "独立查询队列在\(index == 0 ? "模式关闭" : "200ms 无响应")时触发模拟断网，并清理会话")
    }
    for timeoutMS in [60, 800] {
        let net = MemoryNetwork()
        let gate = FastGate(cutoff: { net.emergencyCutoff() }, capture: { nil })
        let script = "printf 'ready\\n> '; while IFS= read -r command; do /bin/sleep 0.2; printf 'enhanced-mode: On\\nsystem-proxy: On\\n> '; done"
        let monitor = try FeatureMonitor(gate: gate, pids: [getpid()], timeoutMS: timeoutMS, testCommand: ("/bin/sh", ["-c", script]))
        if timeoutMS == 60 {
            _ = gate.wakeup.wait(timeout: .now() + 2)
            try expect(gate.trip?.reason.contains("60ms") == true, "自定义 60ms 阈值实际触发查询超时")
        } else {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !monitor.isReady && gate.trip == nil && ProcessInfo.processInfo.systemUptime < deadline { usleep(1000) }
            try expect(monitor.isReady && gate.trip == nil, "自定义 800ms 阈值接受 200ms 查询延迟")
        }
        monitor.stop()
        try expect(monitor.finished.wait(timeout: .now() + 2) == .success, "自定义阈值查询会话安全清理")
    }
    let fastNet = MemoryNetwork(), fastStore = MemoryStore()
    let fastEngine = GuardEngine(network: fastNet, store: fastStore)
    try fastEngine.prepare()
    try expect(!fastEngine.locked && fastNet.mutations == 0 && fastStore.preparedValue != nil,
               "布防前完成恢复快照，不改变网络")
    fastStore.preparedValue = nil
    try fastEngine.prepare()
    try expect(fastStore.preparedValue == nil, "恢复快照未变化时不重复写盘")
    fastNet.current.wifi["en0"] = false
    try fastEngine.prepare()
    try expect(fastStore.preparedValue?.wifi["en0"] == false, "恢复快照变化时重新写盘")
    fastNet.current.wifi["en0"] = true
    try fastEngine.prepare()
    var order: [String] = []
    fastNet.onCutoff = { order.append("cutoff") }
    fastStore.onSave = { order.append("save") }
    let fastGate = FastGate(cutoff: { fastNet.emergencyCutoff() }, capture: {
        (all: fastNet.current.allInterfaces, up: fastNet.current.upInterfaces)
    })
    fastGate.trigger("test fast event")
    try expect(order == ["cutoff"] && fastNet.current.upInterfaces.isEmpty && fastStore.value == nil,
               "事件回调先关闭接口，不写文件、不调用系统配置")
    try expect(GuardEngine(network: fastNet, store: fastStore).locked,
               "快速断网后写锁定标记前崩溃，预备快照使守护重启后保持锁定")
    if let trip = fastGate.trip { fastEngine.lock(trip.reason, fast: trip) }
    try expect(order.first == "cutoff" && order.contains("save"), "持久化和日志在首次关闭接口之后")
    fastGate.trigger("second event")
    try expect(order.filter { $0 == "cutoff" }.count == 1, "快速触发器只触发一次")
    try fastEngine.restore()
    try expect(fastNet.current.upInterfaces.contains("en0") && fastStore.preparedValue == nil,
               "快速断网后仍能恢复原始状态，并清除预备快照")
    let proxyValues: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 6152,
                                     "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152]
    try expect(ProxySignature.parse(proxyValues) != nil, "识别本机 HTTP/HTTPS 系统代理签名")
    var disabledProxy = proxyValues
    disabledProxy["HTTPEnable"] = 0
    try expect(ProxySignature.parse(disabledProxy) == nil, "系统代理配置任一关闭时判为不安全")
    func featureOutput(_ enhanced: String, _ proxy: String) -> CommandResult {
        CommandResult(code: 0, text: "Features:\n  enhanced-mode: \(enhanced)\n  system-proxy: \(proxy)\n")
    }
    try validateFeatures(featureOutput("On", "On"))
    try expect(true, "只接受增强模式和系统代理同时开启")
    let unhealthy = [featureOutput("Off", "On"), featureOutput("On", "Off"), featureOutput("Off", "Off"),
                     featureOutput("Unknown", "On"), CommandResult(code: 0, text: "enhanced-mode: On\n"),
                     CommandResult(code: 0, text: ""), CommandResult(code: -1, text: "command timed out"),
                     CommandResult(code: 1, text: featureOutput("On", "On").text),
                     CommandResult(code: 0, text: featureOutput("On", "On").text + "system-proxy: Off\n")]
    for (index, response) in unhealthy.enumerated() {
        let testNet = MemoryNetwork(), testStore = MemoryStore()
        let testEngine = GuardEngine(network: testNet, store: testStore)
        do { try validateFeatures(response) }
        catch { testEngine.lock("模拟双模式异常：\(error)") }
        try expect(testEngine.locked && testNet.current.upInterfaces.isEmpty,
                   "双模式异常/未知/超时触发锁网，场景 \(index + 1)")
    }
    let timed = runCommand("/bin/sleep", ["10"], timeout: 0.1)
    try expect(timed.code != 0 && timed.text.contains("timed out"), "真实挂起子命令被超时终止")
    let cancelled = runCommand("/bin/sleep", ["10"], timeout: 2, cancel: { true })
    try expect(cancelled.code != 0 && cancelled.text.contains("process exited"), "状态查询可以被进程退出事件中断")
    let net = MemoryNetwork(), store = MemoryStore()
    let engine = GuardEngine(network: net, store: store)
    try expect(!engine.locked && net.mutations == 0, "健康启动不修改网络")
    engine.lock("simulated Surge exit")
    try expect(engine.locked && net.current.upInterfaces.isEmpty, "退出后锁定并关闭所有非回环接口")
    try expect(net.current.services.values.allSatisfy { !$0.enabled }, "关闭所有服务")
    try expect(net.current.wifi["en0"] == false, "关闭 Wi-Fi 电源")
    try expect(store.value?.services["on"]?.enabled == true && store.value?.services["off"]?.enabled == false,
               "保存原来的启用与禁用状态")
    net.current.upInterfaces.insert("en99")
    net.current.upInterfaces.insert("en2")
    net.current.services["new"] = Service(name: "USB Ethernet", enabled: true)
    net.current.services["on"]?.enabled = true
    engine.enforce()
    try expect(net.current.upInterfaces.isEmpty && net.current.services["new"]?.enabled == false,
               "锁定期间关闭新网卡及被重新启用的服务")
    let callsBefore = net.serviceCalls
    engine.enforce()
    try expect(net.serviceCalls == callsBefore, "服务均已关闭时不再锁定系统网络配置")
    net.current.upInterfaces.insert("en3")
    net.current.allInterfaces.insert("en3")
    engine.lastFullEnforce = ProcessInfo.processInfo.systemUptime
    engine.enforceTick()
    try expect(net.current.upInterfaces.isEmpty && net.serviceCalls == callsBefore && store.value?.interfaces["en3"] == true,
               "高频锁定循环先保存新网卡原状态再关闭，不读写网络服务配置")
    let restarted = GuardEngine(network: net, store: store)
    try expect(restarted.locked, "重启守护后仍保持锁定")
    try restarted.restore()
    try expect(net.current.services["on"]?.enabled == true && net.current.services["off"]?.enabled == false &&
               net.current.services["new"]?.enabled == true && net.current.wifi["en0"] == true,
               "手动恢复保留各服务和 Wi-Fi 的原始状态")
    try expect(!net.current.upInterfaces.contains("utun88") && net.current.upInterfaces.contains("en0"),
               "恢复物理接口，不重新开启旧 VPN 接口")
    try expect(!net.current.upInterfaces.contains("en2"), "不打开断网前已关闭的网卡")
    try expect(store.value == nil && !restarted.locked, "恢复成功后才清除备份")
    let failedNet = MemoryNetwork(), failedStore = MemoryStore()
    failedStore.fail = true
    let failed = GuardEngine(network: failedNet, store: failedStore)
    failed.lock("simulated disk failure")
    try expect(failed.locked && failedNet.current.upInterfaces.isEmpty,
               "备份写入失败仍尽力断网")
    let corruptStore = MemoryStore(), corruptNet = MemoryNetwork()
    corruptStore.unreadable = true
    let corrupt = GuardEngine(network: corruptNet, store: corruptStore)
    corrupt.enforce()
    try expect(corrupt.locked && corruptNet.current.upInterfaces.isEmpty && corruptStore.value == nil,
               "备份损坏时断网且不覆盖原备份")
    let prefNet = MemoryNetwork()
    prefNet.serviceFailure = true
    let pref = GuardEngine(network: prefNet, store: MemoryStore())
    pref.lock("preference failure")
    try expect(prefNet.current.upInterfaces.isEmpty, "服务配置失败不影响快速关闭接口")
    do { try pref.restore(); throw GuardError("TEST FAILED: restore should fail") }
    catch { try expect(pref.state != nil, "恢复失败时保留锁定备份") }
    let spareNet = MemoryNetwork(), spareStore = MemoryStore()
    let spare = GuardEngine(network: spareNet, store: spareStore)
    try spare.prepare()
    spare.spareTunnels = true
    spare.lock("simulated proxy off")
    // Surge raises a new tunnel while the network is locked; a cable is plugged in too.
    spareNet.current.upInterfaces.formUnion(["utun9", "en0"])
    spareNet.current.allInterfaces.insert("utun9")
    spare.enforce()
    try expect(spareNet.current.upInterfaces == ["utun9"], "开启自动恢复时锁定只关闭物理网卡，保留 Surge 隧道")
    spareNet.current.upInterfaces.insert("en0")
    spare.lastFullEnforce = ProcessInfo.processInfo.systemUptime
    spare.enforceTick()
    try expect(spareNet.current.upInterfaces == ["utun9"], "高频锁定循环同样只关闭物理网卡")
    try spare.restore(raiseTunnels: true)
    try expect(spareNet.current.upInterfaces.isSuperset(of: ["en0", "utun88", "utun9"]) &&
               !spareNet.current.upInterfaces.contains("en2") && spare.prepared == nil && !spare.locked,
               "自动恢复开启断网前在用且仍存在的隧道，不开原本关闭的网卡，并要求重新写快照")
    var answers = [true, true, false, true, true, true]
    let recovery = RecoveryProbe(check: { answers.removeFirst() })
    var streaks: [Int] = []
    for _ in 0..<6 { _ = recovery.poll(); recovery.settle(); streaks.append(recovery.streak) }
    try expect(streaks == [1, 2, 0, 1, 2, 3], "自动恢复只计连续健康检查，中途异常重新计数")
    // Real kernel event test watches a harmless child, not Surge.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    try child.run()
    defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    let queue = kqueue()
    guard queue >= 0 else { throw GuardError("test kqueue failed") }
    defer { close(queue) }
    try expect(watchExit(queue, child.processIdentifier) == 0, "内核退出事件成功注册")
    child.terminate()
    try expect(waitExit(queue, 2000) == 1, "内核捕获真实子进程退出")
    print("所有自检通过；未更改本机网络。")
}

func latencyTest() throws {
    let queue = DispatchQueue(label: "SurgeGuard.LatencyTest", qos: .userInteractive)
    var samples: [Double] = []
    for _ in 0..<50 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        // The cutoff is explicitly a no-op; this test never calls nativeFastCutoff.
        let gate = FastGate(cutoff: { [] }, capture: { nil })
        let registered = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: child.processIdentifier, eventMask: .exit, queue: queue)
        source.setRegistrationHandler { registered.signal() }
        source.setEventHandler { gate.trigger("latency sample") }
        source.activate()
        defer { source.cancel() }
        guard registered.wait(timeout: .now() + 2) == .success else { throw GuardError("退出监听注册超时") }
        let sent = DispatchTime.now().uptimeNanoseconds
        kill(child.processIdentifier, SIGKILL)
        guard gate.wakeup.wait(timeout: .now() + 2) == .success, let trip = gate.trip else {
            throw GuardError("退出事件测试超时")
        }
        samples.append(Double(trip.enteredAtNanoseconds - sent) / 1_000_000)
        child.waitUntilExit()
    }
    samples.sort()
    print("SurgeDisconnectGuard \(buildVersion)：50 次无害子进程退出事件测试")
    print(String(format: "发出退出信号到模拟断网回调开始：P50 %.3f ms；P95 %.3f ms；最大 %.3f ms",
                 samples[24], samples[47], samples[49]))
    print("仅测本机当时负载下的事件响应；断网回调为空。未关闭任何网卡或 Surge，不能作为实际断网耗时或延迟上限。")
}

func persistentCheck(samples: Int = 1) throws {
    let settings = try GuardSettings.load(from: geteuid() == 0 ? GuardSettings.path : GuardSettings.publicPath)
    let timeoutMS = settings.timeoutMS
    let pids = try surgePIDs()
    guard !pids.isEmpty else { throw GuardError("Surge 未运行") }
    let owners = Set(pids.map { processUID($0) })
    guard !owners.contains(-1) else { throw GuardError("无法确认 Surge 用户") }
    var times: [Double] = []
    for uid in owners.sorted() {
        let session = try PersistentFeatures(uid: uid, cancel: { false })
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            try session.query(timeout: Double(timeoutMS) / 1000)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            if samples > 1 { usleep(UInt32(settings.intervalMS * 1000)) }
        }
    }
    if samples > 1 {
        times.sort()
        print(String(format: "持续连接查询 %d 次：P50 %.3fms；P95 %.3fms；最大 %.3fms", times.count,
                     times[(times.count - 1) / 2], times[Int(Double(times.count - 1) * 0.95)], times.last!))
        print("仅测查询往返，不含故障发生至下一次查询的间隔、系统调度和实际网卡关闭时间。")
    } else { print("持续连接已验证；双模式同时开启，响应在 \(timeoutMS)ms 查询阈值内。") }
}

@main enum SurgeGuardMain {
static func main() {
do {
    switch CommandLine.arguments.dropFirst().first ?? "help" {
    case "daemon": try daemon()
    case "restore":
        try requireRoot()
        let fd = try acquireLock(wait: true)
        defer { close(fd) }
        try GuardEngine(network: MacNetwork(), store: DiskStore()).restore()
    case "lock":
        try requireRoot()
        let fd = try acquireLock()
        defer { close(fd) }
        GuardEngine(network: MacNetwork(), store: DiskStore()).lock(manualLockReason)
    case "check":
        let pids = try surgePIDs()
        let view = try MacNetwork().view(includeWiFiPower: true)
        do {
            let settings = try GuardSettings.load(from: geteuid() == 0 ? GuardSettings.path : GuardSettings.publicPath)
            print("已保存无响应超时：\(settings.timeoutMS)ms；查询间隔：\(settings.intervalMS)ms（下次开启时读取）")
            print("自动恢复网络：\(settings.autoRestore ? "开" : "关")")
        } catch { print("守护设置错误：\(error)") }
        print("Surge：\(pids.isEmpty ? "未运行" : "运行中，PID " + pids.sorted().map(String.init).joined(separator: ", "))")
        print("监控路径：\(appExecutable)")
        do {
            try requireHealthySurge(pids: pids)
            print("双模式：增强模式 On；系统代理 On")
        } catch { print("双模式：不满足保护条件（\(error)）；本只读检查不触发断网。") }
        print("非回环 UP 接口：\(view.upInterfaces.sorted().joined(separator: ", "))")
        for (id, service) in view.services.sorted(by: { $0.key < $1.key }) {
            print("服务 \(service.enabled ? "开" : "关")：\(service.name) [\(id)]")
        }
        print("Wi-Fi 电源：\(view.wifi)")
        print("自检只读取状态，未更改网络。")
    case "surge-running":
        guard !(try surgePIDs()).isEmpty else { throw GuardError("请先打开 /Applications/Surge.app，再启用守护。") }
        print("Surge 主进程正在运行。")
    case "health-check":
        try requireHealthySurge(pids: surgePIDs())
        guard ProxySignature.read() != nil else { throw GuardError("本机系统代理有效配置未同时指向 HTTP/HTTPS 回环代理") }
        print("Surge 主进程运行中，增强模式和系统代理同时开启。")
    case "observer-check":
        let gate = FastGate(cutoff: { [] }, capture: { nil })
        let observer = try ProxyObserver(gate: gate, queue: DispatchQueue(label: "SurgeGuard.ObserverTest"))
        withExtendedLifetime(observer) { print("已成功订阅 macOS 系统代理配置通知；测试回调不关闭网卡。") }
    case "latency-test": try latencyTest()
    case "persistent-check": try persistentCheck()
    case "query-latency-test": try persistentCheck(samples: 200)
    case "ui-state-write":
        try requireRoot()
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard args.count == 2 && ["starting", "disabled", "error"].contains(args[0]) else {
            throw GuardError("界面状态参数无效")
        }
        publishStatus(args[0], args[1])
    case "settings-set", "settings-interval", "settings-auto-restore":
        try requireRoot()
        let command = CommandLine.arguments[1]
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard args.count == 1 else { throw GuardError("设置参数无效") }
        // Change one value and keep the others; an unreadable file is replaced by defaults.
        let saved = try (try? GuardSettings.load()) ?? GuardSettings()
        let settings: GuardSettings
        switch command {
        case "settings-set": settings = try saved.with(timeoutMS: GuardSettings.parse(args[0]))
        case "settings-interval": settings = try saved.with(intervalMS: GuardSettings.parseInterval(args[0]))
        default:
            guard ["on", "off"].contains(args[0]) else { throw GuardError("自动恢复参数只能是 on 或 off") }
            settings = try saved.with(autoRestore: args[0] == "on")
        }
        try settings.save(to: GuardSettings.path)
        try settings.save(to: GuardSettings.publicPath, permissions: 0o644)
        switch command {
        case "settings-set": print("已保存无响应超时 \(settings.timeoutMS)ms；下次开启守护生效。当前守护未重启。")
        case "settings-interval": print("已保存查询间隔 \(settings.intervalMS)ms；下次开启守护生效。当前守护未重启。")
        default: print(settings.autoRestore ? "已开启自动恢复网络，立即生效。" : "已关闭自动恢复网络，立即生效。")
        }
    case "self-test": try selfTest()
    default:
        print("SurgeDisconnectGuard \(buildVersion) — daemon | check | health-check | persistent-check | self-test | latency-test | query-latency-test | observer-check | restore | lock | settings-set <ms> | settings-interval <ms> | settings-auto-restore on|off")
    }
} catch {
    fputs("错误：\(error)\n", stderr)
    exit(1)
}

}
}
