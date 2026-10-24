import Foundation
import Darwin
import Security

let controlVersion = "2.4.0"
let controlSocket = "/var/run/local.surgedisconnect.control.sock"
let controlRoot = "/Library/Application Support/SurgeDisconnectGuard"
let controlLabel = "local.surgedisconnect.control"

struct ControlFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
enum ControlAction: String, Codable {
    case ping, enable, disable, boot, diagnostics, uninstall, prepareUpgrade, setTimeout
}
struct ControlRequest: Codable {
    let protocolVersion: Int
    let action: ControlAction
    let boot: Bool
    let timeoutMS: Int?
    init(_ action: ControlAction, boot: Bool = true, timeoutMS: Int? = nil) {
        protocolVersion = 1; self.action = action; self.boot = boot; self.timeoutMS = timeoutMS
    }
}
struct ControlReply: Codable {
    let version: String
    let success: Bool
    let output: String
    init(_ success: Bool, _ output: String) {
        version = controlVersion; self.success = success; self.output = output
    }
}
func controlAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlFailure("控制连接路径过长。") }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    return address
}
func configureControlSocket(_ fd: Int32, seconds: Int) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
}
func sendControl<T: Encodable>(_ value: T, fd: Int32) throws {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlFailure("控制连接已断开。") }
            offset += count
        }
    }
}
func receiveControl<T: Decodable>(_ type: T.Type, fd: Int32, limit: Int) throws -> T {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
    while data.count <= limit {
        let count = recv(fd, &buffer, min(buffer.count, limit + 1 - data.count), 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ControlFailure("控制连接超时或中断。操作可能仍在后台完成，请查看当前状态后再操作。") }
        data.append(contentsOf: buffer.prefix(count))
        if let end = data.firstIndex(of: 10) {
            guard end == data.count - 1, data.count <= limit else { throw ControlFailure("控制消息格式无效。") }
            return try JSONDecoder().decode(type, from: data.prefix(upTo: end))
        }
    }
    throw ControlFailure("控制消息超过大小限制。")
}
func controlPeerUID(_ fd: Int32) throws -> uid_t {
    var uid = uid_t(0), gid = gid_t(0)
    guard getpeereid(fd, &uid, &gid) == 0 else { throw ControlFailure("无法确认控制连接身份。") }
    return uid
}
func controlCodeHash(attributes: [String: Any], identifier: String) throws -> Data {
    var code: SecCode?
    let flags = SecCSFlags(rawValue: 0)
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, flags, &code) == errSecSuccess,
          let code = code,
          SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
        throw ControlFailure("无法验证界面程序签名，请重新安装权限组件。")
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess, let staticCode = staticCode else {
        throw ControlFailure("无法读取控制程序签名。")
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == identifier,
          let hash = values[kSecCodeInfoUnique as String] as? Data else {
        throw ControlFailure("控制程序签名身份不匹配。")
    }
    return hash
}
func requestControl(_ request: ControlRequest, path: String = controlSocket, requireRoot: Bool = true) throws -> ControlReply {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlFailure("无法建立控制连接。") }
    defer { close(fd) }
    configureControlSocket(fd, seconds: 130)
    var address = try controlAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw ControlFailure("权限组件尚未安装或未运行。") }
    if requireRoot { guard try controlPeerUID(fd) == 0 else { throw ControlFailure("控制端身份异常。") } }
    try sendControl(request, fd: fd)
    return try receiveControl(ControlReply.self, fd: fd, limit: 512_000)
}
