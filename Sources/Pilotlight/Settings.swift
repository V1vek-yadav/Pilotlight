import SwiftUI
import Combine
import ServiceManagement
import ApplicationServices

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    let actions: BoardActions

    @State private var memory = Footprint.memoryMB()
    @State private var cpu = 0.0
    @State private var lastCPU = Footprint.cpuSeconds()
    @State private var hooks = Hooks.installedCount()
    @State private var trusted = AXIsProcessTrusted()
    @State private var login = SMAppService.mainApp.status == .enabled
    // exists only while settings are open
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Tap me on the shoulder when")
            card {
                toggle("Claude needs permission", $prefs.notifyPermission)
                toggle("Claude asks a question", $prefs.notifyQuestion)
                toggle("A session finishes", $prefs.notifyDone)
                toggle("A session fails", $prefs.notifyError)
                toggle("…but stay quiet while I'm in that session's window", $prefs.quietFocused, sub: true)
            }

            title("Lights")
            card {
                row("Live in") { segmented($prefs.place, [(.menubar, "Menu bar"), (.floating, "Floating")]) }
                toggle("Dim floating lights when nothing needs me", $prefs.dimFloating)
                row("Menu bar style") { segmented($prefs.style, [(.lights, "One per session"), (.single, "Single")]) }
                row("Sound") { segmented($prefs.sound, [(.off, "Off"), (.soft, "Soft"), (.distinct, "Distinct")]) }
            }

            title("General")
            card {
                row("Open board") {
                    HStack(spacing: 3) {
                        if !HotKey.active { Text("taken by another app").font(.system(size: 11)).foregroundStyle(.secondary) }
                        KeyCap("⌥"); KeyCap("Space")
                    }
                }
                row("Permission ask waits") {
                    Picker("", selection: $prefs.askTimeout) {
                        ForEach([15.0, 30, 60, 120], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Launch at login") {
                    Toggle("", isOn: Binding(get: { login }, set: setLogin)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                row("Know which VS Code window I'm in") {
                    if trusted {
                        Text("On").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button("Allow…") { Focus.requestAccess() }.buttonStyle(PillButton())
                            .help("Uses Accessibility to read the focused window's title, so asks only step aside for the window you're actually in")
                    }
                }
            }

            title("Claude Code")
            card {
                row(hooks > 0 ? "Hooks connected · \(hooks) events" : "Hooks not installed", dot: hooks > 0 ? Tint.done : Tint.error) {
                    Button(hooks > 0 ? "Repair" : "Install") {
                        actions.repairHooks()
                        hooks = Hooks.installedCount()
                    }
                    .buttonStyle(PillButton())
                }
            }

            title("Footprint · live")
            card {
                row("Memory") { mono(String(format: "%.1f MB", memory)) }
                row("CPU") { mono(String(format: "%.1f %%", cpu)) }
            }

            HStack {
                Spacer()
                Button("Quit Pilotlight", action: actions.quit).buttonStyle(PillButton())
            }
            .padding(.top, 12)
        }
        .onReceive(tick) { _ in
            memory = Footprint.memoryMB()
            let now = Footprint.cpuSeconds()
            cpu = max(0, (now - lastCPU) * 100)
            lastCPU = now
            trusted = AXIsProcessTrusted()
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Pilotlight: login item: \(error.localizedDescription)")
        }
        login = SMAppService.mainApp.status == .enabled
    }

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Color.secondary.opacity(0.7))
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 6)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func row<Trailing: View>(_ label: String, dot: Color? = nil, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).font(.system(size: 12.5))
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 36)
    }

    private func toggle(_ label: String, _ value: Binding<Bool>, sub: Bool = false) -> some View {
        row(label) { Toggle("", isOn: value).toggleStyle(.switch).controlSize(.mini).labelsHidden() }
            .padding(.leading, sub ? 14 : 0)
            .foregroundStyle(sub ? Color.secondary : Color.primary)
    }

    private func segmented<T: Hashable>(_ value: Binding<T>, _ options: [(T, String)]) -> some View {
        Picker("", selection: value) {
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
    }
}
