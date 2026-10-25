import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store.shared
    private let prefs = Prefs.shared
    private let banners = BannerCenter()
    private var status: StatusController!
    private var server: SocketServer?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController(banners: banners)
        banners.actions = status.actions
        store.onAlert = { [unowned self] session, kind in self.alert(session, kind) }
        store.onResolved = { [unowned self] id in self.banners.dismiss(id) }
        status.start()

        let server = SocketServer { incoming in
            MainActor.assumeIsolated { Store.shared.handle(incoming) }
        }
        if !server.start() { NSLog("Pilotlight: could not listen on \(SocketServer.path)") }
        self.server = server

        hotKey = HotKey { [unowned self] in self.status.toggleFromHotKey() }

        // first launch from /Applications wires up Claude Code; after that only the Repair button touches settings.json
        let d = UserDefaults.standard
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !d.bool(forKey: "hooks.installedOnce"),
           Hooks.installedCount() > 0 || (try? Hooks.install()) != nil {
            d.set(true, forKey: "hooks.installedOnce")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.handBackAll()
        unlink(SocketServer.path)
    }

    private func alert(_ s: Session, _ kind: AlertKind) {
        guard prefs.wants(kind), !status.popover.isShown else { return }
        // permission asks already stepped aside in Store when you're looking at the session
        if kind != .permission, prefs.quietFocused, Focus.isLooking(at: s) { return }
        Chime.play(kind, prefs.sound)
        banners.show(s, kind)
    }
}
