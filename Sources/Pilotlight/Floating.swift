import AppKit

/// The floating strip you get by dragging the lights out of the menu bar, plus single lights pulled out of it.
@MainActor final class FloatingController {
    var showBoard: (NSView, NSRectEdge) -> Void = { _, _ in }
    var toggleBoard: (NSView, NSRectEdge) -> Void = { _, _ in }
    var jump: (String) -> Void = { _ in }
    var tooltip: (String) -> String? = { _ in nil }

    @MainActor final class Light {
        let panel: FloatPanel
        let glass: Glass
        let pips: PipsView
        let grip: NSImageView?
        var hovering = false

        init(panel: FloatPanel, glass: Glass, pips: PipsView, grip: NSImageView?) {
            self.panel = panel
            self.glass = glass
            self.pips = pips
            self.grip = grip
        }
    }

    private let store = Store.shared
    private let prefs = Prefs.shared
    private var strip: Light?
    private var solos: [String: Light] = [:]
    private var vertical = UserDefaults.standard.bool(forKey: "strip.vertical")
    private let gripSize: CGFloat = 26, pad: CGFloat = 4, thickness: CGFloat = 32, pitch: CGFloat = 21

    private static let flame: NSImage = {
        let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Pilotlight")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// where ⌥Space should open the board while the lights float
    var anchor: (view: NSView, edge: NSRectEdge)? {
        guard let s = strip else { return nil }
        return (s.glass, edge(for: s.panel))
    }

    func refresh() {
        guard prefs.place == .floating else { teardown(); return }
        for id in Array(solos.keys) where store.sessions[id] == nil { removeSolo(id) }
        let items = store.ordered.filter { solos[$0.id] == nil }.map { ($0.id, $0.state) }
        if strip == nil { createStrip(items) } else { strip?.pips.update(items); resizeStrip() }
        for (id, light) in solos {
            if let state = store.sessions[id]?.state { light.pips.update([(id, state)]) }
        }
        applyDim()
    }

    // MARK: tearing off from the menu bar

    func beginTear(at p: NSPoint) {
        prefs.place = .floating
        refresh()
        if vertical { vertical = false; resizeStrip() }
        moveTear(to: p)
    }

    func moveTear(to p: NSPoint) {
        guard let s = strip else { return }
        s.panel.setFrameOrigin(NSPoint(x: p.x - 16, y: p.y - s.panel.frame.height / 2))
    }

    func endTear(at p: NSPoint) {
        if inMenuBar(p) {
            prefs.place = .menubar
            refresh()
        } else {
            snapStrip()
        }
    }

    // MARK: the strip

    private func createStrip(_ items: [(String, SessionState)]) {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "strip.x") != nil ? NSPoint(x: d.double(forKey: "strip.x"), y: d.double(forKey: "strip.y")) : nil
        let visible = saved.map { p in NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(p) } } ?? false
        if !visible { vertical = false }

        let glass = Glass(frame: .zero)
        let grip = NSImageView(image: Self.flame)
        grip.contentTintColor = .systemBlue
        let pips = PipsView(pitch: pitch, dot: 9, animated: true)
        pips.tooltip = { [weak self] id in self?.tooltip(id) }
        pips.update(items)
        glass.addSubview(grip)
        glass.addSubview(pips)

        let size = stripSize(pips.count)
        let panel = FloatPanel(size: size)
        panel.contentView = glass
        let light = Light(panel: panel, glass: glass, pips: pips, grip: grip)
        glass.onDown = { [weak self] event in self?.stripDown(event) }
        glass.onHover = { [weak self, weak light] inside in
            light?.hovering = inside
            self?.applyDim()
        }
        strip = light

        var origin = saved ?? .zero
        if !visible, let v = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: v.maxX - size.width - 10, y: v.maxY - size.height - 10)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        glass.round(thickness / 2)
        layoutStrip()
        panel.orderFrontRegardless()
    }

    private func stripSize(_ n: Int) -> NSSize {
        let length = pad + gripSize + pitch * CGFloat(n) + pad + 2
        return vertical ? NSSize(width: thickness, height: length) : NSSize(width: length, height: thickness)
    }

    private func layoutStrip() {
        guard let s = strip, let grip = s.grip else { return }
        let b = s.glass.bounds
        s.pips.vertical = vertical
        if vertical {
            grip.frame = NSRect(x: (b.width - gripSize) / 2, y: b.height - pad - gripSize, width: gripSize, height: gripSize)
            s.pips.frame = NSRect(x: 0, y: pad, width: b.width, height: b.height - pad * 2 - gripSize)
        } else {
            grip.frame = NSRect(x: pad, y: (b.height - gripSize) / 2, width: gripSize, height: gripSize)
            s.pips.frame = NSRect(x: pad + gripSize, y: 0, width: b.width - pad * 2 - gripSize, height: b.height)
        }
    }

    /// grows or shrinks with the session count, keeping the edge it sits against still
    private func resizeStrip() {
        guard let s = strip else { return }
        let size = stripSize(s.pips.count)
        var f = s.panel.frame
        if f.size != size {
            let screen = (s.panel.screen ?? NSScreen.main)?.visibleFrame ?? f
            if !vertical && f.midX > screen.midX { f.origin.x = f.maxX - size.width }
            if vertical && f.midY > screen.midY { f.origin.y = f.maxY - size.height }
            f.size = size
            s.panel.setFrame(f, display: true)
            s.panel.invalidateShadow()
        }
        layoutStrip()
    }

    private func stripDown(_ event: NSEvent) {
        guard let s = strip else { return }
        let hit = s.pips.id(at: s.pips.convert(event.locationInWindow, from: nil))
        let origin = s.panel.frame.origin
        let start = NSEvent.mouseLocation
        var pulled: Light?
        trackDrag(in: s.panel,
                  began: { _ in
                      // dragging a light pulls that session out; dragging anything else moves the strip
                      if let hit, store.sessions[hit] != nil {
                          pulled = makeSolo(hit)
                          refresh()
                      }
                  },
                  moved: { p in
                      if let pulled {
                          pulled.panel.setFrameOrigin(NSPoint(x: p.x - 15, y: p.y - 15))
                      } else {
                          s.panel.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
                      }
                  },
                  ended: { p in
                      if let pulled, let hit { dropSolo(hit, pulled, at: p) } else { dropStrip(at: p) }
                  },
                  clicked: { toggleBoard(s.glass, edge(for: s.panel)) })
    }

    private func dropStrip(at p: NSPoint) {
        if inMenuBar(p) {
            prefs.place = .menubar
            refresh()
        } else {
            snapStrip()
        }
    }

    /// magnetic screen edges; the strip turns vertical along the left/right edge, but not in a corner
    private func snapStrip() {
        guard let s = strip, let v = (s.panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let zone: CGFloat = 36
        var f = s.panel.frame
        let left = f.minX - v.minX < zone, right = v.maxX - f.maxX < zone
        let bottom = f.minY - v.minY < zone, top = v.maxY - f.maxY < zone
        let wantVertical = (left || right) && !(top || bottom)
        if wantVertical != vertical {
            vertical = wantVertical
            let size = stripSize(s.pips.count)
            f = NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
        }
        s.panel.setFrame(snapped(f, in: v, left: left, right: right, top: top, bottom: bottom), display: true, animate: true)
        layoutStrip()
        s.panel.invalidateShadow()
        let d = UserDefaults.standard
        d.set(s.panel.frame.minX, forKey: "strip.x")
        d.set(s.panel.frame.minY, forKey: "strip.y")
        d.set(vertical, forKey: "strip.vertical")
    }

    // MARK: single lights

    private func makeSolo(_ id: String) -> Light {
        let glass = Glass(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        glass.round(15)
        let pips = PipsView(pitch: 30, dot: 11, animated: true)
        pips.frame = glass.bounds
        pips.autoresizingMask = [.width, .height]
        pips.tooltip = { [weak self] id in self?.tooltip(id) }
        glass.addSubview(pips)
        let panel = FloatPanel(size: glass.frame.size)
        panel.contentView = glass
        let light = Light(panel: panel, glass: glass, pips: pips, grip: nil)
        glass.onDown = { [weak self] event in self?.soloDown(id) }
        glass.onHover = { [weak self, weak light] inside in
            light?.hovering = inside
            self?.applyDim()
        }
        if let state = store.sessions[id]?.state { pips.update([(id, state)]) }
        solos[id] = light
        panel.orderFrontRegardless()
        return light
    }

    private func soloDown(_ id: String) {
        guard let light = solos[id] else { return }
        let origin = light.panel.frame.origin
        let start = NSEvent.mouseLocation
        trackDrag(in: light.panel,
                  began: { _ in },
                  moved: { p in light.panel.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)) },
                  ended: { p in dropSolo(id, light, at: p) },
                  clicked: {
                      // a pinned light that needs permission opens the board right there; otherwise go to its window
                      guard let s = store.sessions[id] else { return }
                      if s.state == .ask, s.ask?.kind == .permission, s.ask?.handedOff == false {
                          showBoard(light.glass, edge(for: light.panel))
                      } else {
                          jump(id)
                      }
                  })
    }

    private func dropSolo(_ id: String, _ light: Light, at p: NSPoint) {
        let overStrip = strip?.panel.frame.insetBy(dx: -12, dy: -12).contains(p) ?? false
        if overStrip || inMenuBar(p) {
            removeSolo(id)
            refresh()
            return
        }
        guard let v = (light.panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let f = light.panel.frame, zone: CGFloat = 36
        let target = snapped(f, in: v, left: f.minX - v.minX < zone, right: v.maxX - f.maxX < zone,
                             top: v.maxY - f.maxY < zone, bottom: f.minY - v.minY < zone)
        light.panel.setFrame(target, display: true, animate: true)
    }

    private func removeSolo(_ id: String) {
        solos[id]?.panel.close()
        solos[id] = nil
    }

    // MARK: helpers

    private func teardown() {
        strip?.panel.close()
        strip = nil
        for id in Array(solos.keys) { removeSolo(id) }
    }

    private func applyDim() {
        let urgent = { (id: String) -> Bool in
            let state = self.store.sessions[id]?.state
            return state == .ask || state == .error
        }
        if let s = strip {
            s.panel.alphaValue = prefs.dimFloating && !s.pips.ids.contains(where: urgent) && !s.hovering ? 0.55 : 1
        }
        for (id, light) in solos {
            light.panel.alphaValue = prefs.dimFloating && !urgent(id) && !light.hovering ? 0.55 : 1
        }
    }

    private func edge(for panel: NSPanel) -> NSRectEdge {
        let screen = (panel.screen ?? NSScreen.main)?.frame ?? panel.frame
        let f = panel.frame
        if panel === strip?.panel && vertical { return f.midX > screen.midX ? .minX : .maxX }
        return f.midY > screen.midY ? .minY : .maxY
    }

    private func inMenuBar(_ p: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        return p.y > min(screen.visibleFrame.maxY, screen.frame.maxY - 24)
    }

    private func snapped(_ frame: NSRect, in v: NSRect, left: Bool, right: Bool, top: Bool, bottom: Bool) -> NSRect {
        var f = frame
        let margin: CGFloat = 10
        if left { f.origin.x = v.minX + margin } else if right { f.origin.x = v.maxX - f.width - margin }
        if bottom { f.origin.y = v.minY + margin } else if top { f.origin.y = v.maxY - f.height - margin }
        f.origin.x = min(max(f.origin.x, v.minX + 4), v.maxX - f.width - 4)
        f.origin.y = min(max(f.origin.y, v.minY + 4), v.maxY - f.height - 4)
        return f
    }
}
