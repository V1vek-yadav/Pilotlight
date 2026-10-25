import AppKit
import ApplicationServices
import Carbon

/// Borderless panel for the floating strip, pinned lights and banners: never takes focus, shows on every Space.
@MainActor final class FloatPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Rounded vibrancy background that owns every click inside it.
@MainActor final class Glass: NSVisualEffectView {
    var onDown: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func round(_ radius: CGFloat) {
        let edge = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        maskImage = mask
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDown?(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Runs a mouse-tracking loop after a mouseDown and tells a click from a drag. Points are in screen coordinates.
@MainActor func trackDrag(in window: NSWindow, began: (NSPoint) -> Void, moved: (NSPoint) -> Void, ended: (NSPoint) -> Void, clicked: () -> Void) {
    let start = NSEvent.mouseLocation
    var dragging = false
    while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
        let p = NSEvent.mouseLocation
        if event.type == .leftMouseUp {
            if dragging { ended(p) } else { clicked() }
            return
        }
        if !dragging && hypot(p.x - start.x, p.y - start.y) >= 4 {
            dragging = true
            began(p)
        }
        if dragging { moved(p) }
    }
}

enum Focus {
    /// Are you looking at this session right now? Window-level with Accessibility access, app-level without it.
    @MainActor static func isLooking(at s: Session) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == s.host else { return false }
        guard AXIsProcessTrusted() else { return true }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return true }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeBitCast(window, to: AXUIElement.self), kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else { return true }
        return text.localizedCaseInsensitiveContains(s.project)
    }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

enum Jump {
    /// Brings the session's window forward. VS Code-family editors focus the window that has the folder open.
    @MainActor static func to(_ s: Session) {
        let ws = NSWorkspace.shared
        guard s.host != "-", let appURL = ws.urlForApplication(withBundleIdentifier: s.host) else { return }
        if !s.cwd.isEmpty {
            let clis = ["code", "code-insiders", "cursor", "windsurf", "codium"].map { appURL.appendingPathComponent("Contents/Resources/app/bin/\($0)") }
            if let cli = clis.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
                let p = Process()
                p.executableURL = cli
                p.arguments = [s.cwd]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { return }
            }
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: s.host).first {
            running.activate(options: [])
        } else {
            ws.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

enum AppNames {
    @MainActor static func name(_ bundleID: String) -> String {
        switch bundleID {
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.googlecode.iterm2": return "iTerm"
        case "com.apple.Terminal": return "Terminal"
        default:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "its app" }
            return url.deletingPathExtension().lastPathComponent
        }
    }
}

enum Footprint {
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// user + system CPU seconds used by this process so far
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        return seconds + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

enum Chime {
    @MainActor static func play(_ kind: AlertKind, _ style: Prefs.Sound) {
        let name: String
        switch style {
        case .off: return
        case .soft: name = "Tink"
        case .distinct:
            switch kind {
            case .permission: name = "Glass"
            case .question: name = "Ping"
            case .done: name = "Pop"
            case .error: name = "Basso"
            }
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// ⌥Space, via Carbon: the one global-hotkey API that needs no permissions.
@MainActor final class HotKey {
    static private(set) var active = false
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x504C_4C54), id: 1)
        HotKey.active = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
