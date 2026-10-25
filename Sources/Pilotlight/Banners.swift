import AppKit
import SwiftUI

/// Pilotlight draws its own banners instead of using Notification Center: they need no permission,
/// can carry Allow/Deny buttons, and follow the app's own "stay quiet" rules.
@MainActor final class BannerCenter {
    var actions: BoardActions?

    private struct Item {
        let id: String
        let panel: FloatPanel
        var dismissal: Task<Void, Never>?
    }

    private var items: [Item] = []

    func show(_ s: Session, _ kind: AlertKind) {
        dismiss(s.id, animated: false)
        let id = s.id
        let view = BannerView(session: s, kind: kind,
                              open: { [weak self] in self?.dismiss(id); self?.actions?.jump(id) },
                              allow: { [weak self] in self?.actions?.allow(id); self?.dismiss(id) },
                              deny: { [weak self] in self?.actions?.deny(id); self?.dismiss(id) },
                              hover: { [weak self] inside in self?.hover(id, inside) })
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = FloatPanel(size: size)
        panel.contentView = host
        items.insert(Item(id: id, panel: panel), at: 0)
        while items.count > 3 {
            let last = items.removeLast()
            last.dismissal?.cancel()
            last.panel.close()
        }
        layout(entering: panel)
        panel.orderFrontRegardless()
        scheduleDismissal(id, after: 7)
    }

    func dismiss(_ id: String, animated: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        item.dismissal?.cancel()
        if animated {
            item.panel.animator().alphaValue = 0
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                item.panel.close()
            }
        } else {
            item.panel.close()
        }
        layout(entering: nil)
    }

    func dismissAll() {
        for item in items {
            item.dismissal?.cancel()
            item.panel.close()
        }
        items.removeAll()
    }

    private func hover(_ id: String, _ inside: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].dismissal?.cancel()
        if !inside { scheduleDismissal(id, after: 3) }
    }

    private func scheduleDismissal(_ id: String, after seconds: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.dismiss(id) }
        }
    }

    /// stacks banners top-right under the menu bar; a new one slides in from the edge
    private func layout(entering: NSPanel?) {
        guard let v = NSScreen.main?.visibleFrame else { return }
        var top = v.maxY - 10
        for item in items {
            let size = item.panel.frame.size
            let target = NSRect(x: v.maxX - size.width - 10, y: top - size.height, width: size.width, height: size.height)
            if item.panel === entering {
                item.panel.setFrame(target.offsetBy(dx: size.width + 20, dy: 0), display: false)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = item.panel === entering ? 0.3 : 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                item.panel.animator().setFrame(target, display: true)
            }
            top -= size.height + 8
        }
    }
}

/// lets banner buttons work on the first click, without activating Pilotlight
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct BannerView: View {
    let session: Session
    let kind: AlertKind
    let open: () -> Void
    let allow: () -> Void
    let deny: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("PILOTLIGHT")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                if kind == .permission {
                    HStack(spacing: 6) {
                        Button("Allow", action: allow).buttonStyle(PillButton(kind: .primary))
                        Button("Deny", action: deny).buttonStyle(PillButton())
                    }
                    .padding(.top, 7)
                }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 13))
        .frame(width: 350, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: open)
        .onHover(perform: hover)
    }

    private var title: String {
        switch kind {
        case .permission: return "\(session.project) needs permission"
        case .question: return "\(session.project) asked you something"
        case .done: return "\(session.project) finished"
        case .error: return "\(session.project) stopped"
        }
    }

    private var text: String {
        switch kind {
        case .permission: return "\(session.ask?.tool ?? "Tool"): \(session.ask?.detail ?? "")"
        case .question: return session.ask?.detail ?? ""
        case .done:
            guard let r = session.recap else { return "" }
            if let added = r.added, let removed = r.removed { return "\(r.text) · +\(added) −\(removed)" }
            return r.text
        case .error: return session.error ?? ""
        }
    }
}
