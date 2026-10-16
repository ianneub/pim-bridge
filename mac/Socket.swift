// MenuWidgets' way in: a Unix socket that serves the Gmail server to MenuWidgets alone.
//
// It carries the same JSON-RPC as HTTP, one JSON object per line each way, on a
// connection that stays open. There's no bearer token: before every request the peer's
// audit token is checked against a code requirement (MenuWidgets' identifier, signed with
// this app's own certificate, running with the hardened runtime). Tool calls from here
// run as `Caller.menuBar`, which may trash mail without Touch ID.
//
// The hardened runtime matters: without it, anything could start the real MenuWidgets
// with DYLD_INSERT_LIBRARIES and talk to the socket from inside it.

import Darwin
import Foundation
import Security
import CryptoKit

let socketURL = supportDir.appendingPathComponent("bridge.sock")
let menuBarIdentifier = "com.ianneub.menu-widgets"

private let csValid: UInt32 = 0x1          // CS_VALID
private let csGetTaskAllow: UInt32 = 0x4   // CS_GET_TASK_ALLOW: a debugger could attach
private let csRuntime: UInt32 = 0x10000    // CS_RUNTIME: the hardened runtime

/// MenuWidgets signed with the certificate this app is signed with, or nil when this
/// build is signed ad hoc (no certificate to pin, so the socket stays off).
func menuBarRequirement() -> SecRequirement? {
    var me: SecCode?
    var staticMe: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me = me,
          SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe = staticMe,
          SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first
    else { return nil }
    let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    var requirement: SecRequirement?
    let text = "identifier \"\(menuBarIdentifier)\" and certificate leaf = H\"\(hash)\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
    return requirement
}

/// Whether the process on the other end of `fd` is MenuWidgets, as it is right now. The
/// audit token names one exact process, so a reused pid or an exec doesn't pass.
func peerIsMenuBar(_ fd: Int32, _ requirement: SecRequirement) -> Bool {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    var info: CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
          let code = code,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
          // A SecCode works where a SecStaticCode is expected; dynamic information is its live status.
          SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                        SecCSFlags(rawValue: kSecCSDynamicInformation), &info) == errSecSuccess,
          let status = ((info as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value
    else { return false }
    return status & csValid != 0 && status & csRuntime != 0 && status & csGetTaskAllow == 0
}

func startMenuBarSocket() {
    guard let requirement = menuBarRequirement() else {
        return log("socket off: this build is signed ad hoc, so there's no certificate to check MenuWidgets against")
    }
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let path = socketURL.path
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard fd >= 0, path.utf8.count < capacity else { return log("socket off: can't create \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    // The directory is 0700, so nobody else can connect before the chmod either.
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
        close(fd)
        return log("socket off: can't listen on \(path): \(String(cString: strerror(errno)))")
    }
    log("socket \(path) listening for \(menuBarIdentifier)")
    Thread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno != EINTR { log("socket accept failed: \(String(cString: strerror(errno)))"); usleep(100_000) }
                continue
            }
            Thread { serveMenuBar(client, requirement) }.start()
        }
    }.start()
}

private func serveMenuBar(_ fd: Int32, _ requirement: SecRequirement) {
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    guard peerIsMenuBar(fd, requirement) else {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        return log("socket: refused pid \(pid), which isn't \(menuBarIdentifier) signed like this app with the hardened runtime")
    }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
            guard peerIsMenuBar(fd, requirement) else { return log("socket: peer stopped passing the signature check") }
            let reply: [String: Any]?
            if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                reply = gmailServer.queue.sync { handle(gmailServer, message, caller: .menuBar) }
            } else {
                reply = rpcError(NSNull(), -32700, "Parse error: expected one JSON-RPC object per line")
            }
            guard let reply = reply else { continue }
            var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data()
            out.append(0x0A)
            guard writeAll(fd, out) else { return }
        }
        if buffer.count > 4_000_000 { return log("socket: request over 4 MB, closing") }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
