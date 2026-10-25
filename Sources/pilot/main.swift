// Claude Code runs this for every hook event, with the event JSON on stdin.
//   pilot emit  — forward the event to Pilotlight and exit
//   pilot ask   — forward a PermissionRequest, wait for the decision and print it
// When Pilotlight isn't running it exits 0 without output, so Claude Code carries on as normal.
import Darwin

let mode = CommandLine.arguments.dropFirst().first ?? "emit"

func readAll(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return out }
        out.append(contentsOf: buf[0..<n])
    }
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return false }
        off += n
    }
    return true
}

let payload = readAll(STDIN_FILENO)
guard let home = getenv("HOME") else { exit(0) }
let path = Array((String(cString: home) + "/.pilotlight/pilot.sock").utf8)

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(0) }

// the app hosting the session (e.g. com.microsoft.VSCode), so Pilotlight can bring the right window forward
var host = getenv("__CFBundleIdentifier").map { String(cString: $0) } ?? ""
if host.isEmpty || host.contains(" ") { host = "-" }
guard writeAll(fd, Array("pilot/1 \(mode) \(host)\n".utf8)), writeAll(fd, payload) else { exit(0) }
shutdown(fd, SHUT_WR)
guard mode == "ask" else { exit(0) }

// Pilotlight answers within its own timeout; this is only a safety net
var tv = timeval(tv_sec: 140, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
let reply = readAll(fd)
if !reply.isEmpty { _ = writeAll(STDOUT_FILENO, reply) }
exit(0)
