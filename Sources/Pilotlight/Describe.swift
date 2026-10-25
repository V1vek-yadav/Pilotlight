import Foundation

/// Turns hook payloads into the short lines the board shows.
enum Describe {
    static func base(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func short(_ text: String, _ limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    static func activity(_ tool: String, _ input: [String: Any]) -> Activity {
        let str = { (key: String) in input[key] as? String ?? "" }
        switch tool {
        case "Read": return Activity(chip: "Read", line: "Reading \(base(str("file_path")))")
        case "Edit", "MultiEdit": return Activity(chip: "Edit", line: "Editing \(base(str("file_path")))")
        case "Write": return Activity(chip: "Edit", line: "Writing \(base(str("file_path")))")
        case "NotebookEdit": return Activity(chip: "Edit", line: "Editing \(base(str("notebook_path")))")
        case "Bash": return Activity(chip: "Bash", line: short(str("command"), 80))
        case "Grep": return Activity(chip: "Search", line: "Searching for \(short(str("pattern"), 50))")
        case "Glob": return Activity(chip: "Search", line: "Finding \(short(str("pattern"), 50))")
        case "WebFetch": return Activity(chip: "Web", line: "Fetching \(host(str("url")))")
        case "WebSearch": return Activity(chip: "Web", line: "Searching the web for \(short(str("query"), 50))")
        case "Task", "Agent": return Activity(chip: "Task", line: "Delegating: \(short(str("description"), 60))")
        case "TodoWrite": return Activity(chip: "Plan", line: "Updating the todo list")
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                let server = parts.count > 1 ? parts[1].replacingOccurrences(of: "claude_ai_", with: "") : "mcp"
                return Activity(chip: "MCP", line: "\(server): \(parts.dropFirst(2).joined(separator: "__"))")
            }
            return Activity(chip: "Tool", line: tool)
        }
    }

    static func tick(_ tool: String) -> Character {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "e"
        case "Bash": return "b"
        default: return "r"
        }
    }

    static func permission(_ tool: String, _ input: [String: Any]) -> String {
        let keys: [String]
        switch tool {
        case "Bash": keys = ["command"]
        case "Edit", "MultiEdit", "Write", "Read": keys = ["file_path"]
        case "NotebookEdit": keys = ["notebook_path"]
        case "WebFetch": keys = ["url"]
        case "WebSearch": keys = ["query"]
        default: keys = input.keys.sorted()
        }
        return keys.lazy.compactMap { input[$0] as? String }.first ?? tool
    }

    static func question(_ input: [String: Any]) -> String {
        if let questions = input["questions"] as? [[String: Any]], let q = questions.first?["question"] as? String { return q }
        return input["question"] as? String ?? "Claude has a question for you"
    }

    static func error(_ payload: [String: Any]) -> String {
        for key in ["error", "message", "reason"] {
            if let s = payload[key] as? String, !s.isEmpty { return short(s, 120) }
            if let d = payload[key] as? [String: Any], let s = d["message"] as? String { return short(s, 120) }
        }
        return "Stopped with an error"
    }

    static func host(_ url: String) -> String { URL(string: url)?.host ?? url }
}

enum Git {
    /// Branch name from .git/HEAD, walking up from cwd; handles worktrees.
    static func branch(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<16 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                var head = git.appendingPathComponent("HEAD")
                if !isDir.boolValue, let link = try? String(contentsOf: git, encoding: .utf8), let r = link.range(of: "gitdir: ") {
                    let gitdir = link[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    head = URL(fileURLWithPath: gitdir, relativeTo: dir).appendingPathComponent("HEAD")
                }
                guard let ref = try? String(contentsOf: head, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
                return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : String(ref.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return ""
    }
}

/// What a session did, read when it stops: Claude's last message and the diff size.
enum Recaps {
    static func lastAssistantText(_ path: String?) -> String? {
        guard let path, let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private static func clean(_ line: Substring) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while let first = s.first, "#>*-• ".contains(first) { s.removeFirst() }
        return s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func headline(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map(clean).first { $0.count > 2 }.map { Describe.short($0, 100) }
    }

    /// Claude ended its turn with a question, so the session is waiting on you rather than done.
    static func question(_ text: String) -> String? {
        guard let last = text.split(whereSeparator: \.isNewline).map(clean).last(where: { !$0.isEmpty }), last.hasSuffix("?") else { return nil }
        return Describe.short(last, 220)
    }

    static func diffStat(_ cwd: String) -> (files: Int, added: Int, removed: Int)? {
        guard !cwd.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "diff", "--shortstat", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        func number(before word: String) -> Int {
            guard let r = s.range(of: #"(\d+) \#(word)"#, options: .regularExpression) else { return 0 }
            return Int(s[r].split(separator: " ")[0]) ?? 0
        }
        return (number(before: "file"), number(before: "insertion"), number(before: "deletion"))
    }
}
