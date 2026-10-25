import Foundation
import Combine

/// All live sessions, driven by hook events. Everything here runs on the main actor.
@MainActor final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var today = Store.loadToday()

    var onAlert: ((Session, AlertKind) -> Void)?
    /// a session no longer needs a banner (answered, moved on, or seen)
    var onResolved: ((String) -> Void)?

    private var seq = 0
    private var waiting: [String: Waiting] = [:]

    private struct Waiting {
        let conn: Connection
        let tool: String
        let input: [String: Any]
        let suggestions: Any?
        let timeout: Task<Void, Never>
    }

    var ordered: [Session] {
        sessions.values.sorted { a, b in
            if a.state != b.state { return a.state.rawValue < b.state.rawValue }
            return a.state == .ask ? a.since < b.since : a.seq < b.seq
        }
    }

    /// the rows that get number keys, in board order
    func numbered(idleExpanded: Bool) -> [Session] {
        ordered.filter { idleExpanded || $0.state != .idle }
    }

    var summary: String {
        let asks = sessions.values.filter { $0.state == .ask }.count
        let working = sessions.values.filter { $0.state == .working }.count
        if sessions.isEmpty { return "No sessions" }
        if asks > 0 { return "\(working) working · \(asks) need\(asks == 1 ? "s" : "") you" }
        if working > 0 { return "\(working) working · nothing needs you" }
        return "All quiet"
    }

    // MARK: events

    func handle(_ m: Incoming) {
        let p = m.payload
        guard let sid = p["session_id"] as? String, !sid.isEmpty else { m.conn?.reply(nil); return }
        let event = p["hook_event_name"] as? String ?? ""
        prune()

        if event == "SessionEnd" {
            if let w = waiting.removeValue(forKey: sid) { w.timeout.cancel(); w.conn.reply(nil) }
            sessions[sid] = nil
            onResolved?(sid)
            m.conn?.reply(nil)
            return
        }

        let isNew = sessions[sid] == nil
        var s = sessions[sid] ?? newSession(sid, p)
        let wasAsk = s.state == .ask
        s.lastEvent = Date()
        if m.host != "-" { s.host = m.host }
        if let t = p["transcript_path"] as? String { s.transcript = t }
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]
        var alert: AlertKind?

        switch event {
        case "SessionStart":
            if isNew { bumpToday() }
        case "UserPromptSubmit":
            s.branch = Git.branch(s.cwd)
            s.enter(.working)
            s.activity = Activity(chip: "Think", line: "Thinking…")
        case "PreToolUse":
            if tool == "AskUserQuestion" {
                s.enter(.ask)
                s.ask = Ask(kind: .question, tool: tool, detail: Describe.question(input), handedOff: true)
                alert = .question
            } else {
                // a parallel tool call shouldn't clear a permission ask that's still waiting
                if waiting[sid] == nil && s.state != .working { s.enter(.working) }
                s.activity = Describe.activity(tool, input)
                s.tick(Describe.tick(tool))
            }
        case "PostToolUse":
            if s.state == .ask && waiting[sid] == nil { s.enter(.working) }
        case "PermissionRequest":
            if let old = waiting.removeValue(forKey: sid) { old.timeout.cancel(); old.conn.reply(nil) }
            s.enter(.ask)
            s.ask = Ask(kind: .permission, tool: tool, detail: Describe.permission(tool, input), handedOff: true)
            if let conn = m.conn {
                if Prefs.shared.quietFocused && Focus.isLooking(at: s) {
                    conn.reply(nil) // you're looking at it: let VS Code show its own prompt right away
                } else {
                    s.ask?.handedOff = false
                    let seconds = Prefs.shared.askTimeout
                    let timeout = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        if !Task.isCancelled { self?.handOff(sid) }
                    }
                    waiting[sid] = Waiting(conn: conn, tool: tool, input: input, suggestions: p["permission_suggestions"], timeout: timeout)
                    alert = .permission
                }
            }
        case "Stop":
            let worked = Date().timeIntervalSince(s.workStarted)
            s.enter(.done)
            s.unread = true
            s.recap = Recap(text: "Finished", took: worked)
            summarize(sid, transcript: s.transcript, cwd: s.cwd, inline: p["last_assistant_message"] as? String)
        case "StopFailure":
            s.enter(.error)
            s.error = Describe.error(p)
            alert = .error
        default:
            break
        }

        sessions[sid] = s
        if wasAsk && s.state != .ask { onResolved?(sid) }
        if let alert { onAlert?(s, alert) }
    }

    // MARK: actions from the board, banners and keyboard

    func decide(_ sid: String, _ decision: Decision) {
        guard let w = waiting.removeValue(forKey: sid) else { return }
        w.timeout.cancel()
        w.conn.reply(Self.hookOutput(decision, w))
        if var s = sessions[sid] {
            s.enter(.working)
            s.activity = decision == .deny ? Activity(chip: "Think", line: "Permission denied, rethinking…") : Describe.activity(w.tool, w.input)
            sessions[sid] = s
        }
        onResolved?(sid)
    }

    /// done and failed sessions go quiet once you've looked at them
    func seen(_ sid: String) {
        guard var s = sessions[sid], s.state == .done || s.state == .error else { return }
        s.enter(.idle)
        sessions[sid] = s
        onResolved?(sid)
    }

    func handBackAll() {
        for w in waiting.values { w.timeout.cancel(); w.conn.reply(nil) }
        waiting.removeAll()
    }

    // MARK: private

    private func handOff(_ sid: String) {
        guard let w = waiting.removeValue(forKey: sid) else { return }
        w.conn.reply(nil)
        sessions[sid]?.ask?.handedOff = true
        onResolved?(sid)
    }

    private func newSession(_ sid: String, _ p: [String: Any]) -> Session {
        seq += 1
        let cwd = p["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "session" : (cwd as NSString).lastPathComponent
        return Session(id: sid, seq: seq, cwd: cwd, project: project, branch: Git.branch(cwd), host: "-")
    }

    private func summarize(_ sid: String, transcript: String?, cwd: String, inline: String?) {
        Task.detached(priority: .utility) {
            let text = inline ?? Recaps.lastAssistantText(transcript)
            let stat = Recaps.diffStat(cwd)
            await MainActor.run { Store.shared.applyRecap(sid, text: text, stat: stat) }
        }
    }

    private func applyRecap(_ sid: String, text: String?, stat: (files: Int, added: Int, removed: Int)?) {
        guard var s = sessions[sid], s.state == .done, var recap = s.recap else { return }
        if let text, let q = Recaps.question(text) {
            s.enter(.ask)
            s.ask = Ask(kind: .question, tool: "", detail: q, handedOff: true)
            sessions[sid] = s
            onAlert?(s, .question)
            return
        }
        if let text, let line = Recaps.headline(text) { recap.text = line }
        if let stat, stat.files > 0 { recap.files = stat.files; recap.added = stat.added; recap.removed = stat.removed }
        s.recap = recap
        sessions[sid] = s
        onAlert?(s, .done)
    }

    /// sessions that ended without a SessionEnd (crash, closed window) fade out after a while
    private func prune() {
        let cutoff = Date().addingTimeInterval(-8 * 3600)
        for (id, s) in sessions where s.lastEvent < cutoff && waiting[id] == nil && s.state != .working {
            sessions[id] = nil
        }
    }

    private static func hookOutput(_ d: Decision, _ w: Waiting) -> String? {
        var decision: [String: Any] = ["behavior": d == .deny ? "deny" : "allow"]
        if d == .deny { decision["message"] = "Denied from Pilotlight" }
        if d == .always {
            // prefer Claude Code's own "don't ask again" suggestion; otherwise save a rule for this project
            if let suggested = w.suggestions as? [Any], !suggested.isEmpty {
                decision["updatedPermissions"] = suggested
            } else {
                var rule: [String: Any] = ["toolName": w.tool]
                if w.tool == "Bash", let command = w.input["command"] as? String { rule["ruleContent"] = command }
                decision["updatedPermissions"] = [["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "localSettings"]]
            }
        }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: output) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func loadToday() -> Int {
        let d = UserDefaults.standard
        return d.string(forKey: "today.day") == dayKey() ? d.integer(forKey: "today.count") : 0
    }

    private func bumpToday() {
        let d = UserDefaults.standard
        let key = Self.dayKey()
        if d.string(forKey: "today.day") != key { d.set(key, forKey: "today.day"); d.set(0, forKey: "today.count") }
        today = d.integer(forKey: "today.count") + 1
        d.set(today, forKey: "today.count")
    }
}
