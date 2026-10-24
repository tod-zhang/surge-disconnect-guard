import Foundation
import Darwin
import Security
import Dispatch

func controlSelfTest() throws {
    try settingsSelfTest()
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ControlFailure("FAIL " + message) }
        print("PASS " + message)
    }
    func rejected(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }
    func pair() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ControlFailure("socketpair failed") }
        fds.forEach { configureControlSocket($0, seconds: 2) }
        return fds
    }
    let fds = try pair()
    defer { fds.forEach { close($0) } }
    try sendControl(ControlRequest(.disable, boot: false), fd: fds[0])
    let request = try receiveControl(ControlRequest.self, fd: fds[1], limit: 1024)
    try expect(request.action == .disable && !request.boot && request.protocolVersion == 1, "私有协议往返、动作及开机偏好保持一致")
    try expect(rejected { _ = try JSONDecoder().decode(ControlRequest.self, from: Data("{\"protocolVersion\":1,\"action\":\"/bin/sh\",\"boot\":true}".utf8)) }, "拒绝任意命令或非白名单动作")
    let oversized = try pair()
    defer { oversized.forEach { close($0) } }
    let huge = Data(repeating: 65, count: 2048)
    _ = huge.withUnsafeBytes { Darwin.send(oversized[0], $0.baseAddress!, $0.count, 0) }
    try expect(rejected { _ = try receiveControl(ControlRequest.self, fd: oversized[1], limit: 1024) }, "拒绝超长控制请求")
    if getuid() != 0 {
        let hash = try controlCodeHash(attributes: [kSecGuestAttributePid as String: getpid()], identifier: "local.surgedisconnect.control")
        let auth = AuthorizedClient(uid: getuid(), cdHash: hash)
        let rootPeer = try verifyControlClient(fd: fds[0], authorization: auth, identifier: "local.surgedisconnect.control")
        try expect(rootPeer == false,
                   "通过内核审计令牌核验同一用户及已固定的程序签名")
        try expect(rejected { _ = try verifyControlClient(fd: fds[0], authorization: AuthorizedClient(uid: getuid(), cdHash: Data([0])), identifier: "local.surgedisconnect.control") }, "拒绝签名哈希不同的程序")
        try expect(rejected { _ = try verifyControlClient(fd: fds[0], authorization: AuthorizedClient(uid: getuid() + 1, cdHash: hash)) }, "拒绝其他用户")
        try expect(rejected { _ = try verifyControlClient(fd: fds[0], authorization: auth) }, "拒绝使用其他签名标识冒充界面")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sg-control-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let script = temporary.appendingPathComponent("fixed-action.sh")
    try Data("#!/bin/bash\nprintf '%s:%s' \"$1\" \"$2\"\n".utf8).write(to: script)
    let reply = try runControlAction(ControlRequest(.boot, boot: false), script: script.path)
    try expect(reply.success && reply.output == "boot:off", "仅执行固定脚本并传递固定枚举参数")
    try expect(rejected { _ = try runControlAction(ControlRequest(.prepareUpgrade), script: script.path) }, "升级控制动作不能被当作脚本命令执行")
    for ms in [0, 9, 10001] {
        try expect(rejected { _ = try runControlAction(ControlRequest(.setTimeout, timeoutMS: ms), script: script.path) }, "权限服务拒绝越界超时 \(ms)")
    }
    try expect(rejected { _ = try runControlAction(ControlRequest(.setTimeout), script: script.path) }, "权限服务拒绝缺失超时")
    try Data("#!/bin/bash\nprintf '%s:%s:%s' \"$1\" \"$2\" \"$3\"\n".utf8).write(to: script)
    let custom = try runControlAction(ControlRequest(.setTimeout, timeoutMS: 750), script: script.path)
    try expect(custom.success && custom.output == "setTimeout:on:750", "自定义毫秒值经白名单控制通道准确传递")
    let interval = try runControlAction(ControlRequest(.setInterval, boot: false, intervalMS: 50), script: script.path)
    try expect(interval.success && interval.output == "setInterval:off:50", "查询间隔经白名单控制通道准确传递")
    let auto = try runControlAction(ControlRequest(.setAutoRestore, autoRestore: true), script: script.path)
    try expect(auto.success && auto.output == "setAutoRestore:on:on", "自动恢复开关经白名单控制通道准确传递")
    for ms in [4, 1001] {
        try expect(rejected { _ = try runControlAction(ControlRequest(.setInterval, intervalMS: ms), script: script.path) }, "权限服务拒绝越界查询间隔 \(ms)")
    }
    for bad in [ControlRequest(.setInterval), ControlRequest(.setAutoRestore), ControlRequest(.setAutoRestore, timeoutMS: 200, autoRestore: true),
                ControlRequest(.disable, autoRestore: true), ControlRequest(.boot, intervalMS: 20),
                ControlRequest(.enable, autoRestore: false), ControlRequest(.enable, timeoutMS: 200, autoRestore: true)] {
        try expect(rejected { _ = try runControlAction(bad, script: script.path) }, "权限服务拒绝缺失、多余或错位的设置参数 \(bad.action.rawValue)")
    }
    try Data("#!/bin/bash\nprintf '%s:%s:%s:%s:%s' \"$1\" \"$2\" \"$3\" \"$4\" \"$5\"\n".utf8).write(to: script)
    let enable = try runControlAction(ControlRequest(.enable, boot: true, timeoutMS: 300, intervalMS: 25, autoRestore: false), script: script.path)
    try expect(enable.success && enable.output == "enable:on:300:25:off", "开启守护时按固定顺序传递全部设置")
    try Data("#!/bin/bash\nprintf '%s:%s' \"$1\" \"$2\" > \"$0.out\"\n".utf8).write(to: script)
    publishIdleStatus(script: script.path)
    try expect((try? String(contentsOfFile: script.path + ".out", encoding: .utf8)) == "idle:off", "权限组件启动时以固定参数发布空闲状态")
    try Data("#!/bin/bash\necho recovery-failed\nexit 9\n".utf8).write(to: script)
    let failure = try runControlAction(ControlRequest(.disable), script: script.path)
    try expect(!failure.success && failure.output.contains("recovery-failed"), "保留恢复失败及诊断输出")
    try Data("#!/bin/bash\nsleep 60\n".utf8).write(to: script)
    let start = Date()
    try expect(rejected { _ = try runControlAction(ControlRequest(.diagnostics), script: script.path, timeoutSeconds: 0.1) }, "超时停止模拟子进程组")
    try expect(Date().timeIntervalSince(start) < 2, "子进程超时有界")
    print("权限组件自检通过；未安装服务或更改网络。")
}
