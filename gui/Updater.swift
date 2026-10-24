import Foundation
import AppKit
import CryptoKit
import Security

let updateRepository = "tod-zhang/surge-disconnect-guard"
let updateBundleIdentifier = "local.surgedisconnect.ui"
let fallbackAppVersion = buildVersion
/// Release assets must be uploaded by the repository's CI, not by hand.
let updateTrustedUploader = "github-actions[bot]"
var currentAppVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackAppVersion
}

struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        parts = numbers
    }
    var description: String { parts.map(String.init).joined(separator: ".") }
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

struct ReleaseInfo: Decodable {
    struct Asset: Decodable {
        struct Uploader: Decodable { let login: String }
        let name: String
        let size: Int
        let state: String?
        let digest: String?
        let browserDownloadURL: URL
        let uploader: Uploader?
        enum CodingKeys: String, CodingKey {
            case name, size, state, digest, uploader
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// A release that passed the static checks: newer version, CI-uploaded DMG and a SHA-256 digest.
struct UpdateCandidate {
    let version: AppVersion
    let notes: String
    let page: URL
    let download: URL
    let size: Int
    let sha256: String
}

func expectedDMGName(_ version: AppVersion) -> String { "SurgeDisconnectGuard-v\(version).dmg" }

func parseSHA256Digest(_ digest: String?) -> String? {
    guard let digest = digest, digest.hasPrefix("sha256:") else { return nil }
    let hex = digest.dropFirst("sha256:".count).lowercased()
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    return String(hex)
}

func selectUpdate(_ release: ReleaseInfo, current: AppVersion) throws -> UpdateCandidate? {
    guard !release.draft, !release.prerelease, let version = AppVersion(release.tagName) else { return nil }
    guard current < version else { return nil }
    let name = expectedDMGName(version)
    guard let asset = release.assets.first(where: { $0.name == name }) else {
        throw ControlFailure("发现 v\(version)，但发布中没有 \(name)，可能仍在打包，请稍后再试。")
    }
    guard asset.state == nil || asset.state == "uploaded" else { throw ControlFailure("v\(version) 的安装包尚未上传完成，请稍后再试。") }
    guard asset.uploader?.login == updateTrustedUploader else { throw ControlFailure("v\(version) 的安装包不是由自动构建上传，已拒绝下载。") }
    guard let hash = parseSHA256Digest(asset.digest) else { throw ControlFailure("v\(version) 的安装包缺少 SHA-256 校验值，已拒绝下载。") }
    guard asset.size > 0, asset.size < 200_000_000,
          asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host == "github.com",
          asset.browserDownloadURL.path.hasPrefix("/" + updateRepository + "/releases/download/") else {
        throw ControlFailure("v\(version) 的下载地址或大小异常，已拒绝下载。")
    }
    return UpdateCandidate(version: version, notes: release.body ?? "", page: release.htmlURL,
                           download: asset.browserDownloadURL, size: asset.size, sha256: hash)
}

func sha256Hex(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Checks the bundle's seal (every nested file) and that it is this app's signing identity.
func verifyAppBundle(_ app: URL, version: AppVersion) throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code = code else {
        throw ControlFailure("无法读取新版应用的签名。")
    }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    let status = SecStaticCodeCheckValidity(code, flags, nil)
    guard status == errSecSuccess else { throw ControlFailure("新版应用签名校验失败（\(status)），已放弃安装。") }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == updateBundleIdentifier else {
        throw ControlFailure("新版应用的签名身份不是 \(updateBundleIdentifier)，已放弃安装。")
    }
    guard let bundle = Bundle(url: app), bundle.bundleIdentifier == updateBundleIdentifier,
          let text = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          AppVersion(text) == version else {
        throw ControlFailure("新版应用的标识或版本号与发布不一致，已放弃安装。")
    }
}

@discardableResult
func runTool(_ path: String, _ arguments: [String]) throws -> String {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.standardOutput = pipe; task.standardError = pipe
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard task.terminationStatus == 0 else { throw ControlFailure(output.isEmpty ? "\(path) 执行失败。" : output) }
    return output
}

/// Shell command that swaps the app bundle in place, restoring the old one if the swap fails.
func replacementCommand(staged: String, destination: String, token: String) -> String {
    let parent = (destination as NSString).deletingLastPathComponent
    let incoming = parent + "/.SurgeGuardUpdate-" + token + ".app"
    let previous = parent + "/.SurgeGuardPrevious-" + token + ".app"
    let (s, d, i, p) = (shellQuote(staged), shellQuote(destination), shellQuote(incoming), shellQuote(previous))
    return "set -e; /usr/bin/ditto \(s) \(i); /bin/mv \(d) \(p); "
        + "if /bin/mv \(i) \(d); then /bin/rm -rf \(p); else /bin/mv \(p) \(d); /bin/rm -rf \(i); exit 1; fi"
}

final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, ready, installing, failed
    }
    @Published var phase: Phase = .idle
    @Published var message = "尚未检查更新。"
    @Published var progress: Double = 0
    @Published var candidate: UpdateCandidate?
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") }
    }
    /// Incremented when the window should jump to the update panel.
    @Published var revealToken = 0
    let preview: Bool
    private var stagedApp: URL?
    private var workDirectory: URL?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var timer: Timer?

    init(preview: Bool) {
        self.preview = preview
        autoCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
        if let last = UserDefaults.standard.string(forKey: "lastUpdateCheckText") { message = last }
    }
    var busy: Bool { [.checking, .downloading, .installing].contains(phase) }
    var hasUpdate: Bool { candidate != nil && [.available, .downloading, .ready, .installing].contains(phase) }

    func startAutomaticChecks() {
        guard !preview else { return }
        // Delay the first check so launch is not competing with the guard's status refresh.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.automaticCheck() }
    }
    private func automaticCheck() {
        guard autoCheck, !busy, phase != .ready else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        if userInitiated { revealToken += 1 }
        if preview {
            candidate = UpdateCandidate(version: AppVersion("9.9.9")!, notes: "预览：模拟的新版本。", page: URL(string: "https://github.com/" + updateRepository + "/releases")!,
                                        download: URL(string: "https://github.com/")!, size: 1, sha256: String(repeating: "0", count: 64))
            phase = .available
            message = "预览：发现 v9.9.9。下载与安装只会模拟。"
            return
        }
        guard let current = AppVersion(currentAppVersion) else { fail("无法识别当前版本号。"); return }
        phase = .checking
        message = "正在检查 GitHub 上的最新版本…"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(updateRepository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SurgeDisconnectGuard/\(current)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var found: UpdateCandidate?, failure: String?
            do {
                if let error = error { throw ControlFailure("无法连接 GitHub：\(error.localizedDescription)") }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                    throw ControlFailure("GitHub 返回异常（\((response as? HTTPURLResponse)?.statusCode ?? 0)），请稍后再试。")
                }
                found = try selectUpdate(try JSONDecoder().decode(ReleaseInfo.self, from: data), current: current)
            } catch { failure = String(describing: error) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if let failure = failure { self.fail(failure, quiet: !userInitiated); return }
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                if let found = found {
                    self.candidate = found
                    self.phase = .available
                    self.message = "发现新版本 v\(found.version)（当前 v\(current)）。"
                    // Automatic checks also fetch the DMG; installing always waits for the user.
                    if !userInitiated { self.download() }
                } else {
                    self.candidate = nil
                    self.phase = .upToDate
                    self.message = "已是最新版本 v\(current) · \(stamp) 检查"
                    UserDefaults.standard.set(self.message, forKey: "lastUpdateCheckText")
                }
            }
        }.resume()
    }

    func download() {
        guard let candidate = candidate, phase == .available || phase == .failed else { return }
        if preview { phase = .ready; progress = 1; message = "预览：v\(candidate.version) 已下载并通过校验（模拟）。"; return }
        cleanup()
        phase = .downloading
        progress = 0
        message = "正在下载 v\(candidate.version)…"
        let task = URLSession.shared.downloadTask(with: candidate.download) { [weak self] location, response, error in
            var app: URL?, work: URL?, failure: String?
            do {
                if let error = error { throw ControlFailure("下载失败：\(error.localizedDescription)") }
                guard let location = location, (response as? HTTPURLResponse)?.statusCode == 200 else { throw ControlFailure("下载失败，GitHub 未返回安装包。") }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SurgeGuardUpdate-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                work = directory
                let dmg = directory.appendingPathComponent(expectedDMGName(candidate.version))
                try FileManager.default.moveItem(at: location, to: dmg)
                app = try UpdateModel.verifyAndStage(dmg: dmg, in: directory, candidate: candidate)
            } catch { failure = String(describing: error) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.progressObservation = nil
                self.downloadTask = nil
                self.workDirectory = work
                if let failure = failure { self.cleanup(); self.fail(failure); return }
                self.stagedApp = app
                self.progress = 1
                self.phase = .ready
                self.message = "v\(candidate.version) 已下载，SHA-256 与代码签名校验通过，可以安装。"
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { self?.progress = value }
        }
        downloadTask = task
        task.resume()
    }

    /// Runs off the main thread: checks the DMG hash, mounts it read-only and copies out a verified app.
    private static func verifyAndStage(dmg: URL, in directory: URL, candidate: UpdateCandidate) throws -> URL {
        let size = (try FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? NSNumber)?.intValue
        guard size == candidate.size else { throw ControlFailure("安装包大小与发布记录不一致，已删除。") }
        guard try sha256Hex(of: dmg) == candidate.sha256 else { throw ControlFailure("安装包 SHA-256 校验失败，已删除。") }
        let mount = directory.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == updateBundleIdentifier }
        guard apps.count == 1 else { throw ControlFailure("安装包中没有找到本应用。") }
        let staged = directory.appendingPathComponent("Staged").appendingPathComponent(apps[0].lastPathComponent)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: false)
        try runTool("/usr/bin/ditto", [apps[0].path, staged.path])
        // Verify the copy that will actually be installed, not the mounted original.
        try verifyAppBundle(staged, version: candidate.version)
        return staged
    }

    /// Replaces the running app with the verified copy and relaunches. The caller makes sure the guard is off.
    func install() {
        guard phase == .ready, let candidate = candidate else { return }
        if preview { message = "预览：将替换应用并重新打开（模拟，未改动）。"; return }
        guard let staged = stagedApp else { fail("没有已校验的安装包，请重新下载。"); return }
        let destination = Bundle.main.bundleURL.standardizedFileURL
        let path = destination.path
        guard destination.pathExtension == "app", !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") else {
            fail("请先把应用拖到“应用程序”文件夹并从那里打开，再安装更新。")
            return
        }
        phase = .installing
        message = "正在安装 v\(candidate.version)…"
        let parent = destination.deletingLastPathComponent().path
        let command = replacementCommand(staged: staged.path, destination: path, token: UUID().uuidString)
        let needsAdmin = !FileManager.default.isWritableFile(atPath: parent) || !FileManager.default.isWritableFile(atPath: path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                // Re-check right before replacing, in case the staged copy changed on disk.
                try verifyAppBundle(staged, version: candidate.version)
                if needsAdmin {
                    let script = "do shell script " + appleQuote(command) + " with administrator privileges"
                    try runTool("/usr/bin/osascript", ["-e", script])
                } else {
                    try runTool("/bin/bash", ["-c", command])
                }
            } catch {
                let text = String(describing: error)
                failure = text.contains("-128") ? "已取消管理员授权，未安装更新。" : "安装失败，原应用保持不变：\(text)"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let failure = failure { self.phase = .ready; self.message = failure; return }
                UserDefaults.standard.set(candidate.version.description, forKey: "justUpdatedTo")
                self.cleanup()
                // Wait for this process to exit, then open the new copy as the current user.
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                                      "sh", String(getpid()), path]
                try? relaunch.run()
                NSApp.terminate(nil)
            }
        }
    }

    func openReleasePage() {
        if let page = candidate?.page { NSWorkspace.shared.open(page) }
        else { NSWorkspace.shared.open(URL(string: "https://github.com/\(updateRepository)/releases")!) }
    }

    /// Shown once by the new copy after a successful update.
    func consumeUpdateNotice() -> String? {
        guard let version = UserDefaults.standard.string(forKey: "justUpdatedTo") else { return nil }
        UserDefaults.standard.removeObject(forKey: "justUpdatedTo")
        guard version == currentAppVersion else { return nil }
        message = "已更新到 v\(version)。"
        return "已更新到 v\(version)。首次操作需重新授权一次，之后点击“开启守护”恢复保护。"
    }

    private func fail(_ text: String, quiet: Bool = false) {
        // A failed background check (e.g. while the network is locked) keeps the previous state.
        if quiet && phase == .checking { phase = candidate == nil ? .idle : .available; return }
        phase = .failed
        message = text
    }
    private func cleanup() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation = nil
        stagedApp = nil
        if let work = workDirectory { try? FileManager.default.removeItem(at: work) }
        workDirectory = nil
    }
}

func updaterSelfTest() -> Bool {
    guard let a = AppVersion("v2.4.0"), let b = AppVersion("2.10"), let c = AppVersion("2.4.0.1") else { return false }
    guard a < b, a < c, AppVersion("2.4") == a, !(a < a), AppVersion("2.x") == nil, AppVersion("") == nil, AppVersion("v1..2") == nil else { return false }
    guard expectedDMGName(a) == "SurgeDisconnectGuard-v2.4.0.dmg" else { return false }
    let hash = String(repeating: "ab", count: 32)
    guard parseSHA256Digest("sha256:" + hash) == hash, parseSHA256Digest("md5:" + hash) == nil,
          parseSHA256Digest("sha256:xyz") == nil, parseSHA256Digest(nil) == nil else { return false }
    func release(tag: String, uploader: String = updateTrustedUploader, withDigest: Bool = true,
                 host: String = "github.com", prerelease: Bool = false) -> ReleaseInfo? {
        let name = "SurgeDisconnectGuard-v\(AppVersion(tag)?.description ?? tag).dmg"
        var asset: [String: Any] = ["name": name, "size": 1000, "state": "uploaded", "uploader": ["login": uploader],
                                    "browser_download_url": "https://\(host)/\(updateRepository)/releases/download/\(tag)/\(name)"]
        if withDigest { asset["digest"] = "sha256:" + String(repeating: "ab", count: 32) }
        let object: [String: Any] = ["tag_name": tag, "body": "notes", "html_url": "https://github.com/\(updateRepository)/releases/tag/\(tag)",
                                     "draft": false, "prerelease": prerelease, "assets": [asset]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ReleaseInfo.self, from: data)
    }
    // 1 = update offered, 0 = nothing newer, 2 = rejected with an error.
    func outcome(_ release: ReleaseInfo?) -> Int {
        guard let release = release else { return -1 }
        do { return try selectUpdate(release, current: a) == nil ? 0 : 1 } catch { return 2 }
    }
    guard outcome(release(tag: "v2.5.0")) == 1, outcome(release(tag: "v2.4.0")) == 0, outcome(release(tag: "v2.3.9")) == 0,
          outcome(release(tag: "v9.0.0", prerelease: true)) == 0,
          outcome(release(tag: "v2.5.0", uploader: "someone")) == 2, outcome(release(tag: "v2.5.0", withDigest: false)) == 2,
          outcome(release(tag: "v2.5.0", host: "example.com")) == 2 else { return false }
    guard let newer = release(tag: "v2.5.0"), let found = try? selectUpdate(newer, current: a),
          found.version == AppVersion("2.5.0"), found.sha256 == hash else { return false }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sg-updater-\(getpid())")
    defer { try? FileManager.default.removeItem(at: temp) }
    guard (try? Data("abc".utf8).write(to: temp)) != nil,
          (try? sha256Hex(of: temp)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else { return false }
    let command = replacementCommand(staged: "/tmp/a'b/New.app", destination: "/Applications/Surge 断网守护.app", token: "T")
    guard command.contains("'/tmp/a'\\''b/New.app'"), command.contains("'/Applications/.SurgeGuardUpdate-T.app'") else { return false }
    return true
}
