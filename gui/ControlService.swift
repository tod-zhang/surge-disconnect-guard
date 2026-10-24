import Foundation
import Darwin
import Security
import Dispatch

@_silgen_name("sg_process_uid") func controlProcessUID(_ pid: Int32) -> Int32
@_silgen_name("sg_spawn") func controlSpawn(_ path: UnsafePointer<CChar>,
    _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ output: UnsafeMutablePointer<Int32>, _ pid: UnsafeMutablePointer<Int32>) -> Int32

struct AuthorizedClient: Codable {
    let uid: uid_t
    let cdHash: Data
}
let clientConfig = controlRoot + "/control-client.json"
let controlScript = controlRoot + "/control-actions.sh"

func authorizeControlClient(pid: Int32) throws {
    let uid = controlProcessUID(pid)
    guard uid > 0 else { throw ControlFailure("请从普通用户的图形界面安装权限组件。") }
    let hash = try controlCodeHash(attributes: [kSecGuestAttributePid as String: pid], identifier: "local.surgedisconnect.ui")
    let data = try JSONEncoder().encode(AuthorizedClient(uid: uid_t(uid), cdHash: hash))
    try data.write(to: URL(fileURLWithPath: clientConfig), options: .atomic)
    guard chmod(clientConfig, 0o600) == 0, chown(clientConfig, 0, 0) == 0 else { throw ControlFailure("无法保存控制权限。") }
}
func verifyControlClient(fd: Int32, authorization: AuthorizedClient, identifier: String = "local.surgedisconnect.ui") throws -> Bool {
    let uid = try controlPeerUID(fd)
    // Root already has complete control; this path is used for safe helper upgrades.
    if uid == 0 { return true }
    guard uid == authorization.uid else { throw ControlFailure("只有安装时授权的本机用户可以控制守护。") }
    var token = [UInt32](repeating: 0, count: 8)
    var length = socklen_t(token.count * MemoryLayout<UInt32>.size)
    let result = token.withUnsafeMutableBytes { getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0.baseAddress, &length) }
    guard result == 0, length == 32 else { throw ControlFailure("无法确认控制连接的审计身份。") }
    let data = token.withUnsafeBytes { Data($0) }
    let hash = try controlCodeHash(attributes: [kSecGuestAttributeAudit as String: data], identifier: identifier)
    guard hash == authorization.cdHash else { throw ControlFailure("界面版本已变化，需要重新授权权限组件。") }
    return false
}
func runControlAction(_ request: ControlRequest, script: String = controlScript, timeoutSeconds: Double = 120) throws -> ControlReply {
    guard [.enable, .disable, .boot, .diagnostics, .uninstall, .setTimeout].contains(request.action) else { throw ControlFailure("操作不被允许。") }
    if request.action == .setTimeout && request.timeoutMS == nil { throw ControlFailure("缺少超时参数。") }
    if request.timeoutMS != nil && ![.enable, .setTimeout].contains(request.action) { throw ControlFailure("此操作不接受超时参数。") }
    var arguments = [request.action.rawValue, request.boot ? "on" : "off"]
    if let ms = request.timeoutMS { arguments.append(String(try GuardSettings(timeoutMS: ms).timeoutMS)) }
    return try runFixedScript(arguments, script: script, timeoutSeconds: timeoutSeconds)
}
// Internal only: never reachable from a client request.
func publishIdleStatus(script: String = controlScript) {
    do {
        let reply = try runFixedScript(["idle", "off"], script: script, timeoutSeconds: 20)
        if !reply.success { fputs("无法发布空闲状态：\(reply.output)\n", stderr) }
    } catch { fputs("无法发布空闲状态：\(error)\n", stderr) }
}
func runFixedScript(_ scriptArguments: [String], script: String, timeoutSeconds: Double) throws -> ControlReply {
    let arguments = ["/bin/bash", script] + scriptArguments
    let pointers = arguments.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    let argv = pointers + [nil]
    let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "HOME=/var/root"]
    let envPointers = environment.map { strdup($0) }
    defer { envPointers.forEach { free($0) } }
    let envp = envPointers + [nil]
    var output: Int32 = -1, pid: Int32 = 0
    let code = argv.withUnsafeBufferPointer { args in
        envp.withUnsafeBufferPointer { env in controlSpawn("/bin/bash", args.baseAddress!, env.baseAddress!, &output, &pid) }
    }
    guard code == 0 else { throw ControlFailure("无法启动固定控制操作：\(code)") }
    defer { close(output) }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
    var captured = Data(), status: Int32 = 0
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        // Bound both memory and each drain cycle, so output cannot bypass the deadline.
        for _ in 0..<32 {
            let count = read(output, &buffer, buffer.count)
            if count <= 0 { break }
            captured.append(contentsOf: buffer.prefix(count))
            if captured.count > 64_000 { captured.removeFirst(captured.count - 64_000) }
        }
        if waitpid(pid, &status, WNOHANG) == pid { break }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            throw ControlFailure("控制操作超过 \(Int(timeoutSeconds)) 秒，已停止操作；恢复备份会保留，请查看诊断。")
        }
        usleep(10_000)
    }
    // The child has exited; collect remaining bytes without blocking on grandchildren.
    for _ in 0..<32 {
        let count = read(output, &buffer, buffer.count)
        if count <= 0 { break }
        captured.append(contentsOf: buffer.prefix(count))
        if captured.count > 64_000 { captured.removeFirst(captured.count - 64_000) }
    }
    return ControlReply(status == 0, String(decoding: captured, as: UTF8.self))
}
func removeControlInstallation() {
    unlink("/Library/LaunchDaemons/" + controlLabel + ".plist")
    for name in ["sg-control", "control-actions.sh", "control-client.json"] { unlink(controlRoot + "/" + name) }
    unlink(controlSocket)
    _ = rmdir(controlRoot)
}
func serveControl() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: clientConfig))
    let authorization = try JSONDecoder().decode(AuthorizedClient.self, from: data)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw ControlFailure("无法建立权限组件。") }
    defer { close(listener); unlink(controlSocket) }
    configureControlSocket(listener, seconds: 0)
    umask(0o077)
    unlink(controlSocket)
    var address = try controlAddress(controlSocket)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chown(controlSocket, authorization.uid, 0) == 0,
          chmod(controlSocket, 0o600) == 0, listen(listener, 8) == 0 else { throw ControlFailure("无法发布私有控制连接。") }
    let slots = DispatchSemaphore(value: 4)
    let operation = NSLock()
    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { if errno == EINTR { continue }; throw ControlFailure("控制监听已中断。") }
        if slots.wait(timeout: .now()) != .success { close(client); continue }
        configureControlSocket(client, seconds: 2)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(client); slots.signal() }
            do {
                let rootClient = try verifyControlClient(fd: client, authorization: authorization)
                let request = try receiveControl(ControlRequest.self, fd: client, limit: 1024)
                guard request.protocolVersion == 1 else { throw ControlFailure("控制协议版本不匹配。") }
                if request.action == .ping { try sendControl(ControlReply(true, "权限组件已就绪。"), fd: client); return }
                guard request.action != .prepareUpgrade || rootClient else { throw ControlFailure("此操作需要管理员权限。") }
                guard operation.try() else { try sendControl(ControlReply(false, "另一项操作正在进行，请稍后重试。"), fd: client); return }
                defer { operation.unlock() }
                if request.action == .prepareUpgrade {
                    try sendControl(ControlReply(true, "权限组件已停止，可安全更新。"), fd: client)
                    unlink(controlSocket)
                    exit(0)
                }
                let reply = try runControlAction(request)
                if request.action == .uninstall && reply.success { removeControlInstallation() }
                // Finish privileged work even if the UI disconnects before receiving the reply.
                try? sendControl(reply, fd: client)
                if request.action == .uninstall && reply.success { exit(0) }
            } catch { try? sendControl(ControlReply(false, String(describing: error)), fd: client) }
        }
    }
}

@main enum ControlService {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "self-test" { try controlSelfTest(); return }
            guard geteuid() == 0 else { throw ControlFailure("权限组件必须由系统管理员安装。") }
            switch args.first {
            case "authorize":
                guard args.count == 2, let pid = Int32(args[1]) else { throw ControlFailure("无效的界面进程。") }
                try authorizeControlClient(pid: pid)
            case "stop":
                let reply = try requestControl(ControlRequest(.prepareUpgrade))
                guard reply.success else { throw ControlFailure(reply.output) }
            case "uninstall":
                let reply = try requestControl(ControlRequest(.uninstall, boot: false))
                guard reply.success else { throw ControlFailure(reply.output) }
                print(reply.output)
            case "daemon":
                publishIdleStatus()
                try serveControl()
            default: throw ControlFailure("无效的权限组件命令。")
            }
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
