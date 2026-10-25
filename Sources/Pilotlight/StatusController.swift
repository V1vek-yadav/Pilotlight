import AppKit
import Combine
import SwiftUI

/// The menu bar item, the board popover and its keyboard shortcuts.
@MainActor final class StatusController: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    let model = BoardModel()
    private(set) var actions: BoardActions!

    private let store = Store.shared
    private let prefs = Prefs.shared
    private let banners: BannerCenter
    private let floating = FloatingController()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var shown: (lights: [SessionState], title: String, tip: String)?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var closedAt = Date.distantPast
    private var refreshQueued = false
    private var bag = Set<AnyCancellable>()

    private static let flame: NSImage? = {
        let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Pilotlight")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }()

    init(banners: BannerCenter) {
        self.banners = banners
        super.init()
        actions = BoardActions(
            allow: { [unowned self] id in self.store.decide(id, .allow) },
            deny: { [unowned self] id in self.store.decide(id, .deny) },
            always: { [unowned self] id in self.store.decide(id, .always) },
            jump: { [unowned self] id in self.jump(id) },
            repairHooks: { _ = try? Hooks.install() },
            quit: { NSApp.terminate(nil) })
        floating.showBoard = { [unowned self] view, edge in self.showBoard(from: view, edge: edge) }
        floating.toggleBoard = { [unowned self] view, edge in self.toggleBoard(from: view, edge: edge) }
        floating.jump = { [unowned self] id in self.jump(id) }
        floating.tooltip = { [unowned self] id in self.tooltip(id) }
    }

    func start() {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // The button stays a plain image + title: a custom layer-backed subview in a status item makes
        // macOS re-snapshot it in a loop. Drags are caught here instead of in a subview.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let button = self.item.button, event.window === button.window else { return event }
            if event.type == .rightMouseDown { self.showMenu(); return nil }
            guard self.prefs.place == .menubar else { return event }
            self.trayMouseDown()
            return nil
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.objectWillChange.sink { [unowned self] _ in self.queueRefresh() }.store(in: &bag)
        prefs.objectWillChange.sink { [unowned self] _ in self.queueRefresh() }.store(in: &bag)
        refresh()
    }

    // MARK: menu bar

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let button = item.button else { return }
        let order = store.ordered
        let asks = order.filter { $0.state == .ask }.count

        // lights: empty means "show the flame" (the lights are floating)
        var lights: [SessionState] = []
        var title = ""
        if prefs.place == .floating {
            title = asks > 0 ? " \(asks)" : ""
        } else if order.isEmpty {
            lights = [.idle]
        } else if prefs.style == .single {
            lights = [order[0].state]
            let live = order.filter { $0.state != .idle }.count
            title = asks > 0 ? " \(asks)" : live > 0 ? " \(live)" : ""
        } else {
            lights = order.prefix(6).map(\.state)
            if order.count > 6 { title = " +\(order.count - 6)" }
        }
        let tip = order.isEmpty ? "Pilotlight: no Claude sessions yet" : order.map { "\($0.project) — \(Self.word($0.state))" }.joined(separator: "\n")

        // only touch the button when what it shows changed; every change costs the menu bar a snapshot
        if shown?.lights != lights || shown?.title != title {
            button.image = lights.isEmpty ? Self.flame : Self.lightsImage(lights)
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: asks > 0 && !title.contains("+") ? NSColor.systemOrange : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])
        }
        if shown?.tip != tip {
            button.toolTip = tip
            button.setAccessibilityLabel("Pilotlight: \(store.summary)")
        }
        shown = (lights, title, tip)
        floating.refresh()
    }

    private static func word(_ state: SessionState) -> String {
        switch state {
        case .ask: return "needs you"
        case .error: return "stopped"
        case .working: return "working"
        case .done: return "done"
        case .idle: return "idle"
        }
    }

    /// the lights as a still image, the way status items are meant to be drawn
    private static func lightsImage(_ lights: [SessionState]) -> NSImage {
        let pitch: CGFloat = 11, dot: CGFloat = 7, height: CGFloat = 18, pad: CGFloat = 3
        let size = NSSize(width: pad * 2 + pitch * CGFloat(lights.count - 1) + dot, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            for (i, state) in lights.enumerated() {
                let d = state == .ask ? dot + 1 : dot
                let cx = pad + dot / 2 + pitch * CGFloat(i)
                let rect = NSRect(x: cx - d / 2, y: (height - d) / 2, width: d, height: d)
                let color = NSColor(cgColor: LightPalette.color(state)) ?? .gray
                NSGraphicsContext.saveGraphicsState()
                if state == .idle {
                    color.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.7, dy: 0.7))
                    ring.lineWidth = 1.4
                    ring.stroke()
                } else {
                    if state == .ask {
                        let glow = NSShadow()
                        glow.shadowColor = color
                        glow.shadowBlurRadius = 3
                        glow.set()
                    }
                    color.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func trayMouseDown() {
        guard let window = item.button?.window else { return }
        trackDrag(in: window,
                  began: { p in floating.beginTear(at: p) },
                  moved: { p in floating.moveTear(to: p) },
                  ended: { p in floating.endTear(at: p) },
                  clicked: { if let button = item.button { toggleBoard(from: button, edge: .minY) } })
    }

    @objc private func buttonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if let button = item.button {
            toggleBoard(from: button, edge: .minY)
        }
    }

    private func tooltip(_ id: String) -> String? {
        guard let s = store.sessions[id] else { return id == "none" ? "Pilotlight: no Claude sessions yet" : nil }
        return "\(s.project) · \(s.statusLine)"
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        add("Open Board", #selector(menuOpen))
        add(prefs.place == .floating ? "Dock Lights in Menu Bar" : "Float Lights", #selector(menuToggleFloat))
        add("Settings…", #selector(menuSettings), ",")
        menu.addItem(.separator())
        add("Quit Pilotlight", #selector(menuQuit), "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func menuOpen() { if let button = item.button { showBoard(from: button, edge: .minY) } }
    @objc private func menuToggleFloat() { prefs.place = prefs.place == .floating ? .menubar : .floating }
    @objc private func menuSettings() { menuOpen(); model.showSettings = true }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: board

    func toggleFromHotKey() {
        if popover.isShown { popover.performClose(nil); return }
        if let anchor = floating.anchor {
            showBoard(from: anchor.view, edge: anchor.edge)
        } else if let button = item.button {
            showBoard(from: button, edge: .minY)
        }
    }

    func toggleBoard(from view: NSView, edge: NSRectEdge) {
        if popover.isShown { popover.performClose(nil); return }
        // the click that closed a transient popover shouldn't immediately reopen it
        guard Date().timeIntervalSince(closedAt) > 0.4 else { return }
        showBoard(from: view, edge: edge)
    }

    func showBoard(from view: NSView, edge: NSRectEdge) {
        if popover.isShown { popover.performClose(nil) }
        let root = BoardView(actions: actions).environmentObject(store).environmentObject(prefs).environmentObject(model)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        if view === item.button { item.button?.highlight(true) }
        banners.dismissAll()
        startKeys()
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        // drop the SwiftUI tree so nothing renders while the board is closed
        popover.contentViewController = nil
        item.button?.highlight(false)
        model.showSettings = false
        stopKeys()
        if NSApp.isActive { NSApp.deactivate() }
    }

    private func jump(_ id: String) {
        if popover.isShown { popover.performClose(nil) }
        guard let s = store.sessions[id] else { return }
        Jump.to(s)
        store.seen(id)
    }

    // MARK: keyboard

    private func startKeys() {
        stopKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { // esc
            if model.showSettings { model.showSettings = false } else { popover.performClose(nil) }
            return true
        }
        guard !model.showSettings, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let n = Int(key), (1...9).contains(n) {
            let list = store.numbered(idleExpanded: model.idleExpanded)
            if n <= list.count { jump(list[n - 1].id) }
            return true
        }
        guard let first = store.ordered.first(where: { $0.state == .ask }), let ask = first.ask else { return false }
        let answerable = ask.kind == .permission && !ask.handedOff
        switch e.keyCode {
        case 36, 76: // return, enter
            if answerable { store.decide(first.id, .allow) } else { jump(first.id) }
            return true
        case 51 where answerable: // delete
            store.decide(first.id, .deny)
            return true
        default:
            if key == "a" && answerable { store.decide(first.id, .always); return true }
            return false
        }
    }
}
