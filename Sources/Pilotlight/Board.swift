import SwiftUI

@MainActor final class BoardModel: ObservableObject {
    @Published var showSettings = false
    @Published var idleExpanded = false
}

struct BoardActions {
    var allow: (String) -> Void
    var deny: (String) -> Void
    var always: (String) -> Void
    var jump: (String) -> Void
    var repairHooks: () -> Void
    var quit: () -> Void
}

enum Tint {
    static let work = Color(nsColor: .systemBlue)
    static let ask = Color(nsColor: .systemOrange)
    static let done = Color(nsColor: .systemGreen)
    static let error = Color(nsColor: .systemRed)
    static let flame = LinearGradient(colors: [Color(red: 0.66, green: 0.84, blue: 1), Color(red: 0.16, green: 0.36, blue: 1)], startPoint: .top, endPoint: .bottom)

    static func of(_ state: SessionState) -> Color {
        switch state {
        case .working: return work
        case .ask: return ask
        case .done: return done
        case .error: return error
        case .idle: return .secondary
        }
    }
}

// MARK: - small pieces

struct Dot: View {
    let state: SessionState
    var body: some View {
        Group {
            if state == .idle {
                Circle().strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.4)
            } else {
                Circle().fill(Tint.of(state))
            }
        }
        .frame(width: 8, height: 8)
    }
}

struct KeyCap: View {
    let key: String
    var onAccent = false
    init(_ key: String, onAccent: Bool = false) {
        self.key = key
        self.onAccent = onAccent
    }
    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(onAccent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .foregroundStyle(onAccent ? Color.white : Color.secondary)
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}

struct PillButton: ButtonStyle {
    enum Kind { case primary, soft, link }
    var kind: Kind = .soft

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, kind == .link ? 4 : 10)
            .frame(height: 26)
            .foregroundStyle(kind == .primary ? Color.white : kind == .link ? Color.accentColor : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7).fill(kind == .primary ? Color.accentColor : kind == .soft ? Color.primary.opacity(0.08) : Color.clear))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Ticks only while the board is on screen; SwiftUI stops the timeline when the popover closes.
struct Elapsed: View {
    enum Kind { case running, waiting, ago }
    let since: Date
    let kind: Kind

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since), kind))
                .font(.system(size: 11.5)).monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m):\(String(format: "%02d", sec))"
    }

    static func format(_ t: TimeInterval, _ kind: Kind) -> String {
        switch kind {
        case .running: return duration(t)
        case .waiting: return "waiting \(duration(t))"
        case .ago:
            if t < 45 { return "just now" }
            let m = Int((t / 60).rounded())
            return m < 60 ? "\(m)m ago" : "\(m / 60)h ago"
        }
    }
}

/// The last tool calls, newest on the right. Blue ones edited files.
struct Ticks: View {
    let ticks: [Character]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(ticks.suffix(18).enumerated()), id: \.offset) { _, t in
                Capsule()
                    .fill(t == "e" ? Tint.work : Color.secondary.opacity(t == "b" ? 0.8 : 0.4))
                    .frame(width: 2, height: t == "e" ? 10 : t == "b" ? 8 : 5)
            }
        }
        .frame(height: 10, alignment: .bottom)
        .help("Last tool calls · blue = file edits")
    }
}

struct ProjectLine: View {
    let s: Session
    var weight: Font.Weight = .semibold
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(s.project).font(.system(size: 13, weight: weight)).lineLimit(1)
            if !s.branch.isEmpty {
                Text(s.branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

// MARK: - rows

struct AskCard: View {
    let s: Session
    let number: Int?
    let first: Bool
    let actions: BoardActions

    var body: some View {
        let ask = s.ask ?? Ask(kind: .question, tool: "", detail: "", handedOff: true)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Dot(state: .ask)
                ProjectLine(s: s)
                Spacer(minLength: 8)
                Elapsed(since: s.since, kind: .waiting)
            }
            if ask.kind == .permission { permission(ask) } else { question(ask) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11).fill(Tint.ask.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Tint.ask.opacity(0.38)))
        .padding(.bottom, 8)
    }

    private var app: String { AppNames.name(s.host) }

    @ViewBuilder private func permission(_ ask: Ask) -> some View {
        HStack(spacing: 6) { Text("Wants to use"); Chip(text: ask.tool) }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 7)
        Text(verbatim: (ask.tool == "Bash" ? "$ " : "") + ask.detail)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(.top, 6).padding(.bottom, 9)
        if ask.handedOff {
            Text("This one is waiting in \(app). Answer it there.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Button { actions.jump(s.id) } label: {
                HStack(spacing: 6) {
                    Text("Answer in \(app)")
                    Image(systemName: "arrow.up.right")
                    if let number { KeyCap("\(number)", onAccent: true) }
                }
            }
            .buttonStyle(PillButton(kind: .primary))
        } else {
            HStack(spacing: 6) {
                Button { actions.allow(s.id) } label: {
                    HStack(spacing: 6) { Text("Allow"); if first { KeyCap("⏎", onAccent: true) } }
                }
                .buttonStyle(PillButton(kind: .primary))
                Button { actions.deny(s.id) } label: {
                    HStack(spacing: 6) { Text("Deny"); if first { KeyCap("⌫") } }
                }
                .buttonStyle(PillButton())
                Button { actions.always(s.id) } label: {
                    HStack(spacing: 6) { Text("Always"); if first { KeyCap("A") } }
                }
                .buttonStyle(PillButton())
                .help("Allow, and save a rule so Claude stops asking for this in this project")
                Spacer(minLength: 0)
                Button { actions.jump(s.id) } label: {
                    HStack(spacing: 4) { Text("Open"); if let number { KeyCap("\(number)") } }
                }
                .buttonStyle(PillButton(kind: .link))
            }
        }
    }

    @ViewBuilder private func question(_ ask: Ask) -> some View {
        Text("Asked you")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 7)
        Text(ask.detail)
            .font(.system(size: 12.5))
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .overlay(alignment: .leading) { Rectangle().fill(Tint.ask).frame(width: 2) }
            .padding(.top, 6).padding(.bottom, 9)
        Button { actions.jump(s.id) } label: {
            HStack(spacing: 6) {
                Text("Reply in \(app)")
                Image(systemName: "arrow.up.right")
                if first { KeyCap("⏎", onAccent: true) } else if let number { KeyCap("\(number)", onAccent: true) }
            }
        }
        .buttonStyle(PillButton(kind: .primary))
    }
}

struct SessionRow: View {
    let s: Session
    let number: Int?
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Dot(state: s.state).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    ProjectLine(s: s, weight: s.state == .done && !s.unread ? .medium : .semibold)
                    detail
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    ZStack(alignment: .trailing) {
                        Elapsed(since: s.state == .working ? s.workStarted : s.since, kind: s.state == .working ? .running : .ago)
                            .opacity(hover && number != nil ? 0 : 1)
                        if hover, let number { KeyCap("\(number)") }
                    }
                    if s.state == .working { Ticks(ticks: s.ticks) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Color.primary.opacity(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var detail: some View {
        switch s.state {
        case .working:
            HStack(spacing: 6) {
                if let a = s.activity {
                    Chip(text: a.chip)
                    Text(a.line).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        case .done:
            if let r = s.recap {
                Text(r.text)
                    .font(.system(size: 12)).lineLimit(2)
                    .foregroundStyle(s.unread ? Color.primary : Color.secondary)
                HStack(spacing: 6) {
                    if let f = r.files { Text("\(f) file\(f == 1 ? "" : "s")") }
                    if let a = r.added { Text("+\(a)").foregroundStyle(Tint.done) }
                    if let d = r.removed { Text("−\(d)").foregroundStyle(Tint.error) }
                    Text("took \(Elapsed.duration(r.took))")
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            }
        case .error:
            Text(s.error ?? "Stopped").font(.system(size: 12)).foregroundStyle(Tint.error).lineLimit(2)
            Text("Open \(AppNames.name(s.host)) to retry").font(.system(size: 11)).foregroundStyle(.tertiary)
        default:
            Text("Waiting for your next prompt").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - the board

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct BoardView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var model: BoardModel
    let actions: BoardActions
    @State private var height: CGFloat = 120
    @State private var hooksInstalled = true

    var body: some View {
        VStack(spacing: 0) {
            if model.showSettings {
                header(back: true)
                scroll { SettingsView(actions: actions) }
            } else {
                header(back: false)
                scroll { board }
                footer
            }
        }
        .frame(width: 380)
        .onAppear { hooksInstalled = Hooks.installedCount() > 0 }
    }

    private func scroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 8).padding(.bottom, 8)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .frame(height: min(max(height, 40), 540))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }

    private func header(back: Bool) -> some View {
        HStack(spacing: 8) {
            if back {
                Button { model.showSettings = false } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            } else {
                Image(systemName: "flame.fill").foregroundStyle(Tint.flame)
                Text("Pilotlight").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(store.summary).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                Button { model.showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")
            }
        }
        .padding(.leading, back ? 6 : 14).padding(.trailing, 10)
        .padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder private var board: some View {
        let ordered = store.ordered
        let numbered = store.numbered(idleExpanded: model.idleExpanded)
        let number: (Session) -> Int? = { s in numbered.firstIndex { $0.id == s.id }.flatMap { $0 < 9 ? $0 + 1 : nil } }
        let asks = ordered.filter { $0.state == .ask }
        let idle = ordered.filter { $0.state == .idle }

        VStack(alignment: .leading, spacing: 0) {
            if !hooksInstalled {
                HStack {
                    Text("Claude Code isn't connected yet.").font(.system(size: 12))
                    Spacer()
                    Button("Connect") { actions.repairHooks(); hooksInstalled = Hooks.installedCount() > 0 }.buttonStyle(PillButton(kind: .primary))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tint.error.opacity(0.08)))
                .padding(.top, 6)
            }
            if ordered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "flame").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("No Claude sessions yet").font(.system(size: 13, weight: .medium))
                    Text("Start Claude Code in VS Code and it shows up here. Sessions that were already running appear after their next message.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 12)
            } else {
                sectionTitle("Needs you", asks.count, tint: asks.isEmpty ? nil : Tint.ask)
                if asks.isEmpty {
                    HStack(spacing: 8) { Dot(state: .done); Text("Nothing needs you right now.") }
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                } else {
                    ForEach(asks) { s in AskCard(s: s, number: number(s), first: s.id == asks.first?.id, actions: actions) }
                }
                ForEach([("Stopped", SessionState.error), ("Working", .working), ("Done", .done)], id: \.0) { title, state in
                    let list = ordered.filter { $0.state == state }
                    if !list.isEmpty {
                        sectionTitle(title, list.count, tint: nil)
                        ForEach(list) { s in SessionRow(s: s, number: number(s)) { actions.jump(s.id) } }
                    }
                }
                if !idle.isEmpty {
                    Button { model.idleExpanded.toggle() } label: {
                        HStack(spacing: 10) {
                            Dot(state: .idle)
                            Text("\(idle.count) idle · \(idle.map(\.project).joined(separator: ", "))").lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").rotationEffect(.degrees(model.idleExpanded ? 90 : 0))
                        }
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    if model.idleExpanded {
                        ForEach(idle) { s in SessionRow(s: s, number: number(s)) { actions.jump(s.id) } }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, _ count: Int, tint: Color?) -> some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text("\(count)")
        }
        .font(.system(size: 11, weight: .semibold)).tracking(0.6)
        .foregroundStyle(tint ?? Color.secondary.opacity(0.7))
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 3) {
            Text("Today · \(store.today) session\(store.today == 1 ? "" : "s")")
            Spacer()
            KeyCap("⌥"); KeyCap("Space")
            Text("board ·").padding(.trailing, 2)
            KeyCap("1"); Text("–"); KeyCap("9")
            Text("jump")
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}
