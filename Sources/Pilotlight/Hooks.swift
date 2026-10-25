import Foundation

/// Pilotlight's entries in ~/.claude/settings.json. Every other hook in the file is left alone.
enum Hooks {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "StopFailure", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "~/.claude/settings.json isn't valid JSON, so it was left untouched" }
    }

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json").resolvingSymlinksInPath()
    }

    private static var pilot: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pilot").path
    }

    private static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains("Pilotlight.app/Contents/MacOS/pilot") == true
    }

    static func installedCount() -> Int {
        guard let hooks = (try? load())?["hooks"] as? [String: Any] else { return 0 }
        return events.filter { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { ($0["hooks"] as? [Any] ?? []).contains(where: isOurs) }
        }.count
    }

    @discardableResult static func install() throws -> Int {
        var root = try load()
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:]).hooks
        for event in events {
            let entry: [String: Any] = [
                "type": "command",
                "command": "'\(pilot)' \(event == "PermissionRequest" ? "ask" : "emit")",
                "timeout": event == "PermissionRequest" ? 150 : 5,
            ]
            var group: [String: Any] = ["hooks": [entry]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        root["hooks"] = hooks
        try save(root)
        return events.count
    }

    @discardableResult static func uninstall() throws -> Int {
        var root = try load()
        guard let hooks = root["hooks"] as? [String: Any] else { return 0 }
        let result = strip(hooks)
        guard result.removed > 0 else { return 0 }
        root["hooks"] = result.hooks.isEmpty ? nil : result.hooks
        try save(root)
        return result.removed
    }

    /// removes our entries so reinstalling never duplicates them
    private static func strip(_ hooks: [String: Any]) -> (hooks: [String: Any], removed: Int) {
        var out = hooks
        var removed = 0
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            var removedHere = 0
            for var group in groups {
                let entries = group["hooks"] as? [Any] ?? []
                let left = entries.filter { !isOurs($0) }
                removedHere += entries.count - left.count
                if left.count != entries.count {
                    if left.isEmpty { continue }
                    group["hooks"] = left
                }
                kept.append(group)
            }
            if removedHere > 0 { out[event] = kept.isEmpty ? nil : kept }
            removed += removedHere
        }
        return (out, removed)
    }

    private static func load() throws -> [String: Any] {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return root
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        let url = settingsURL
        let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.pilotlight-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
