import AppKit

let args = CommandLine.arguments
if args.contains("--install-hooks") || args.contains("--uninstall-hooks") {
    do {
        if args.contains("--install-hooks") {
            print("Pilotlight: registered \(try Hooks.install()) hook events in ~/.claude/settings.json")
        } else {
            print("Pilotlight: removed \(try Hooks.uninstall()) hook entries from ~/.claude/settings.json")
        }
        exit(0)
    } catch {
        fputs("Pilotlight: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
