// The app's two windows, About and Settings. They are plain AppKit windows holding SwiftUI views,
// opened from the menu: a SwiftUI `Window` scene would open by itself at launch, and the `Settings`
// scene can't be opened the same way on macOS 13 and 14.

import AppKit
import SwiftUI
#if canImport(TotalMixOSC)
import TotalMixOSC
#endif

/// Opens the app's windows, one of each, bringing the app forward (a menu-bar app is otherwise in
/// the background).
@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]

    /// Shows the window named `id`, with fresh content, making it the first time.
    static func show<Content: View>(_ id: String, title: String, @ViewBuilder content: () -> Content) {
        let window = open[id] ?? {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            open[id] = window
            return window
        }()
        window.title = title
        window.contentViewController = NSHostingController(rootView: content().tint(Brand.amber))
        if !window.isVisible { window.center() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window named `id`, if it is open.
    static func close(_ id: String) {
        open[id]?.close()
    }
}

/// The About window: the icon at 128 points, large enough for its details, and what the app is.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: Brand.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .accessibilityLabel("Performance Bridge icon")
            Text("Performance Bridge")
                .font(.title2.weight(.semibold))
            Text(Brand.version)
                .foregroundStyle(.secondary)
            Text("Connects hardware control surfaces to RME TotalMix FX, for mixing live.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Link("github.com/adambier/performance-bridge",
                 destination: URL(string: "https://github.com/adambier/performance-bridge")!)
            VStack(spacing: 2) {
                Text("© 2026 Adam Arthur Bier. MIT License.")
                Text("Not affiliated with or endorsed by RME, Melbourne Instruments, or Novation.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 360)
        .fixedSize()
    }
}

/// The Settings window: where to find TotalMix FX and the Roto-Control. Apply saves the settings
/// and restarts the connections.
struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @State private var edited = SavedSettings.load()

    private let saved = SavedSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section {
                    TextField("Computer running TotalMix FX", text: $edited.host, prompt: Text("localhost"))
                    portField("Incoming port", value: $edited.incomingPort,
                              override: model.portOverrides.incoming)
                    portField("Outgoing port", value: $edited.outgoingPort,
                              override: model.portOverrides.outgoing)
                } header: {
                    Text("TotalMix FX")
                        .font(.headline)
                } footer: {
                    Text("As set in TotalMix FX's preferences, under OSC, with Global OSC on. TotalMix FX receives on its incoming port and sends to its outgoing port. Its defaults are 7001 and 9001.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("MIDI port name", text: $edited.rotoPortName, prompt: Text("Roto"))
                } header: {
                    Text("Roto-Control")
                        .font(.headline)
                        .padding(.top, 8)
                } footer: {
                    Text("The name, or part of the name, of the Roto-Control's MIDI ports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !edited.isValid {
                Text("Ports must be from 1 to 65535 and different from each other, and no field may be empty.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Defaults") { edited = SavedSettings() }
                Spacer()
                Button("Revert") { edited = saved }
                    .disabled(edited == saved)
                Button("Apply") {
                    model.apply(edited)
                    Windows.close("settings")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!edited.isValid || edited == saved)
            }
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func portField(_ label: String, value: Binding<Int>, override: UInt16?) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
        if let override {
            Text("Port \(String(override)) from the command line is in use instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
