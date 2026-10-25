import Foundation
import Darwin

/// One hook event as `pilot` sent it.
struct Incoming {
    let mode: String
    let host: String
    let payload: [String: Any]
    /// open only for `pilot ask`, which waits for a decision
    let conn: Connection?
}

/// The socket a waiting `pilot ask` is blocked on. Replying (or not) closes it exactly once.
final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// nil means "no decision": Claude Code shows its normal prompt
    func reply(_ text: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if let bytes = text.map({ Array($0.utf8) }) {
            bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)
    }

    deinit { reply(nil) }
}

/// Listens on ~/.pilotlight/pilot.sock. Idle, it's a blocked accept: no timers, no polling.
final class SocketServer {
    static var path: String { NSHomeDirectory() + "/.pilotlight/pilot.sock" }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pilotlight.socket")
    private let onMessage: (Incoming) -> Void

    init(onMessage: @escaping (Incoming) -> Void) {
        self.onMessage = onMessage
    }

    func start() -> Bool {
        mkdir(NSHomeDirectory() + "/.pilotlight", 0o700)
        let path = Self.path
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); return false }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        self.source = source
        return true
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            // accepted sockets inherit O_NONBLOCK on Darwin; reads below should block (briefly)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            read(client)
        }
    }

    /// `pilot` writes "pilot/1 <mode> <host>\n" then the hook JSON, then closes its write side.
    private func read(_ client: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = Darwin.read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard let newline = data.firstIndex(of: 10) else { close(client); return }
        let header = String(decoding: data[..<newline], as: UTF8.self).split(separator: " ")
        guard header.count >= 3, header[0] == "pilot/1",
              let payload = (try? JSONSerialization.jsonObject(with: data[(newline + 1)...])) as? [String: Any]
        else { close(client); return }

        let mode = String(header[1])
        let conn: Connection? = mode == "ask" ? Connection(fd: client) : nil
        if conn == nil { close(client) }
        let message = Incoming(mode: mode, host: String(header[2]), payload: payload, conn: conn)
        let deliver = onMessage
        DispatchQueue.main.async { deliver(message) }
    }
}
