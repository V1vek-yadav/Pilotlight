import Foundation

/// Raw values give the board's sort order: what needs you first.
enum SessionState: Int {
    case ask, error, working, done, idle
}

enum AlertKind { case permission, question, done, error }
enum Decision { case allow, deny, always }

struct Activity {
    var chip: String
    var line: String
}

struct Ask {
    enum Kind { case permission, question }
    var kind: Kind
    var tool: String
    var detail: String
    /// true once the prompt is VS Code's to answer (timed out, or you were already looking at it)
    var handedOff: Bool
}

struct Recap {
    var text: String
    var files: Int?
    var added: Int?
    var removed: Int?
    var took: TimeInterval
}

struct Session: Identifiable {
    let id: String
    let seq: Int
    var cwd: String
    var project: String
    var branch: String
    var host: String
    var state: SessionState = .idle
    var since = Date()
    var workStarted = Date()
    var lastEvent = Date()
    var activity: Activity?
    var ticks: [Character] = []
    var ask: Ask?
    var recap: Recap?
    var error: String?
    var unread = false
    var transcript: String?

    mutating func enter(_ next: SessionState) {
        if next == .working && state != .working && state != .ask { workStarted = Date() }
        state = next
        since = Date()
        if next != .ask { ask = nil }
        if next != .error { error = nil }
        if next == .working { recap = nil; unread = false }
    }

    mutating func tick(_ kind: Character) {
        ticks.append(kind)
        if ticks.count > 18 { ticks.removeFirst(ticks.count - 18) }
    }

    var statusLine: String {
        switch state {
        case .working: return activity?.line ?? "Working"
        case .ask:
            guard let ask, ask.kind == .permission else { return "asked you something" }
            return "wants to use \(ask.tool): \(Describe.short(ask.detail, 60))"
        case .done: return "done · \(recap?.text ?? "")"
        case .error: return error ?? "stopped"
        case .idle: return "idle"
        }
    }
}
