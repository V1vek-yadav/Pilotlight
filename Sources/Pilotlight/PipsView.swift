import AppKit

/// Light colors, fixed rather than appearance-dependent so they read on light and dark backgrounds alike
/// and never need restyling when the appearance changes.
enum LightPalette {
    static func color(_ state: SessionState) -> CGColor {
        switch state {
        case .working: return CGColor(srgbRed: 0.18, green: 0.50, blue: 1.00, alpha: 1)
        case .ask: return CGColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
        case .done: return CGColor(srgbRed: 0.19, green: 0.78, blue: 0.35, alpha: 1)
        case .error: return CGColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
        case .idle: return CGColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }
}

/// A row (or column) of session lights for the floating strip and pinned lights, one CALayer each.
/// The breathing / ripple are Core Animation animations that run in the window server.
/// (The menu bar item is drawn as a plain image instead; see StatusController.)
@MainActor final class PipsView: NSView, NSViewToolTipOwner {
    let pitch: CGFloat
    let dot: CGFloat
    let animated: Bool
    var leading: CGFloat = 0 { didSet { relayout() } }
    var vertical = false { didSet { if vertical != oldValue { relayout() } } }
    var tooltip: ((String) -> String?)?

    private(set) var ids: [String] = []
    private var states: [String: SessionState] = [:]
    private var dots: [String: CALayer] = [:]

    init(pitch: CGFloat, dot: CGFloat, animated: Bool) {
        self.pitch = pitch
        self.dot = dot
        self.animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var count: Int { ids.count }
    var length: CGFloat { leading + pitch * CGFloat(ids.count) }

    func update(_ items: [(String, SessionState)]) {
        let newIDs = items.map { $0.0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, l) in dots where !newIDs.contains(id) {
            l.removeFromSuperlayer()
            dots[id] = nil
            states[id] = nil
        }
        for (id, state) in items {
            let l: CALayer
            if let existing = dots[id] {
                l = existing
            } else {
                l = CALayer()
                layer?.addSublayer(l)
                dots[id] = l
            }
            if states[id] != state {
                states[id] = state
                style(l, state)
            }
        }
        ids = newIDs
        CATransaction.commit()
        relayout()
    }

    func id(at point: NSPoint) -> String? {
        let along = vertical ? bounds.height - point.y : point.x
        guard along >= leading else { return nil }
        let i = Int((along - leading) / pitch)
        return ids.indices.contains(i) ? ids[i] : nil
    }

    // MARK: events

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let id = id(at: point) else { return "" }
        return tooltip?(id) ?? ""
    }

    // MARK: drawing

    private func cell(_ i: Int) -> NSRect {
        let start = leading + pitch * CGFloat(i)
        return vertical
            ? NSRect(x: 0, y: bounds.height - start - pitch, width: bounds.width, height: pitch)
            : NSRect(x: start, y: 0, width: pitch, height: bounds.height)
    }

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, id) in ids.enumerated() {
            guard let l = dots[id] else { continue }
            let d = states[id] == .ask ? dot + 1 : dot
            let c = cell(i)
            l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            l.cornerRadius = d / 2
            l.position = CGPoint(x: c.midX, y: c.midY)
            l.sublayers?.forEach { $0.frame = l.bounds; $0.cornerRadius = d / 2 }
        }
        CATransaction.commit()
        removeAllToolTips()
        for i in ids.indices { addToolTip(cell(i), owner: self, userData: nil) }
    }

    private func style(_ l: CALayer, _ state: SessionState) {
        l.removeAllAnimations()
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        l.borderWidth = 0
        l.shadowOpacity = 0
        switch state {
        case .working:
            l.backgroundColor = LightPalette.color(state)
            if animated { l.add(Self.breathe, forKey: "breathe") }
        case .ask:
            l.backgroundColor = LightPalette.color(state)
            if animated {
                let ring = CALayer()
                ring.borderColor = LightPalette.color(state)
                ring.borderWidth = 1.5
                ring.frame = l.bounds
                ring.add(Self.ripple, forKey: "ripple")
                l.addSublayer(ring)
            } else {
                // a still glow stands in for the ripple
                l.shadowColor = LightPalette.color(state)
                l.shadowOffset = .zero
                l.shadowRadius = 2.5
                l.shadowOpacity = 0.9
            }
        case .done, .error:
            l.backgroundColor = LightPalette.color(state)
        case .idle:
            l.backgroundColor = nil
            l.borderWidth = 1.4
            l.borderColor = LightPalette.color(state)
        }
    }

    private static let breathe: CAAnimation = {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = 0.35
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 0.78
        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = 0.95
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return group
    }()

    private static let ripple: CAAnimation = {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 2.3
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }()
}
