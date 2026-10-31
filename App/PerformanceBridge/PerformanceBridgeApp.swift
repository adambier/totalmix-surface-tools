// Performance Bridge: a first look at the menu-bar app (macOS only). Run it from the package with
// `swift run PerformanceBridge`, or `swift run PerformanceBridge --in-port 7004 --out-port 9004` to
// override the ports saved in Settings; quit `sbdev bridge` first, since both need TotalMix's
// outgoing port and the Roto-Control's MIDI ports. The released app will be built by make-app.sh
// instead.

import AppKit
import SwiftUI
#if canImport(BridgeEngine)
import BridgeEngine
#endif
#if canImport(TotalMixOSC)
import TotalMixOSC
#endif
#if canImport(SurfaceCore)
import SurfaceCore
#endif

@main
struct PerformanceBridgeApp: App {
    @StateObject private var model = BridgeModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .tint(Brand.amber)
        } label: {
            Image(nsImage: Brand.menuBarImage)
                .accessibilityLabel("Performance Bridge")
        }
    }
}

/// The app's look: the icon's amber as its accent color, and the menu-bar glyph (a one-color
/// template image from Design/AppIcon, which macOS colors to suit the menu bar).
enum Brand {
    /// The app's resources: the package's resource bundle under `swift run`, the app bundle when
    /// make-app.sh builds everything as one module.
    static var resources: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    static let amber = Color(red: 1, green: 0xB1 / 255.0, blue: 0x3D / 255.0)

    /// The app icon at 128 points (the 128 and 256 px art from Design/AppIcon), for the About
    /// window.
    static let appIcon: NSImage = resources.image(forResource: "AppIcon") ?? NSApplication.shared.applicationIconImage

    /// "Version 1.0 (12)" from the app bundle, or "Development build" when run with `swift run`.
    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info["CFBundleVersion"] as? String, build != short { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }()

    static let menuBarImage: NSImage = {
        let image = resources.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Performance Bridge")
            ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// The settings kept between launches, in the user defaults.
struct SavedSettings: Equatable {
    var host = TotalMixEndpoint.standard.host
    var incomingPort = Int(TotalMixEndpoint.standard.incomingPort)
    var outgoingPort = Int(TotalMixEndpoint.standard.outgoingPort)
    var rotoPortName = BridgeSettings().rotoPortName

    private enum Key {
        static let host = "totalMixHost"
        static let incomingPort = "totalMixIncomingPort"
        static let outgoingPort = "totalMixOutgoingPort"
        static let rotoPortName = "rotoPortName"
    }

    static func load(_ defaults: UserDefaults = .standard) -> SavedSettings {
        var saved = SavedSettings()
        if let host = defaults.string(forKey: Key.host), !host.isEmpty { saved.host = host }
        if let port = defaults.object(forKey: Key.incomingPort) as? Int, SavedSettings.isPort(port) { saved.incomingPort = port }
        if let port = defaults.object(forKey: Key.outgoingPort) as? Int, SavedSettings.isPort(port) { saved.outgoingPort = port }
        if let name = defaults.string(forKey: Key.rotoPortName), !name.isEmpty { saved.rotoPortName = name }
        return saved
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(host, forKey: Key.host)
        defaults.set(incomingPort, forKey: Key.incomingPort)
        defaults.set(outgoingPort, forKey: Key.outgoingPort)
        defaults.set(rotoPortName, forKey: Key.rotoPortName)
    }

    static func isPort(_ value: Int) -> Bool { (1...65_535).contains(value) }

    /// Whether every field can be used.
    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Self.isPort(incomingPort) && Self.isPort(outgoingPort)
            && incomingPort != outgoingPort && !rotoPortName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The engine and its latest status, for the menu.
@MainActor
final class BridgeModel: ObservableObject {
    @Published var status = BridgeStatus()
    @Published private(set) var engine: BridgeEngine
    /// Ports given on the command line (`--in-port`, `--out-port`), which win over the saved ones.
    let portOverrides: (incoming: UInt16?, outgoing: UInt16?)

    private static let homeSubmixKey = "homeSubmix"

    init() {
        let arguments = CommandLine.arguments
        func port(_ option: String) -> UInt16? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return UInt16(arguments[index + 1])
        }
        portOverrides = (port("--in-port"), port("--out-port"))
        engine = BridgeEngine(settings: Self.settings(SavedSettings.load(), overrides: portOverrides))
        start()
    }

    /// The engine's settings from the saved settings, the command line, and the menu's choices.
    private static func settings(_ saved: SavedSettings, overrides: (incoming: UInt16?, outgoing: UInt16?)) -> BridgeSettings {
        var settings = BridgeSettings()
        settings.endpoint = TotalMixEndpoint(host: saved.host.trimmingCharacters(in: .whitespaces),
                                             incomingPort: overrides.incoming ?? UInt16(saved.incomingPort),
                                             outgoingPort: overrides.outgoing ?? UInt16(saved.outgoingPort))
        settings.rotoPortName = saved.rotoPortName.trimmingCharacters(in: .whitespaces)
        settings.playbacksOnNewPage = UserDefaults.standard.bool(forKey: "playbacksOnNewPage")
        settings.homeSubmix = UserDefaults.standard.object(forKey: homeSubmixKey) as? Int
        return settings
    }

    private func start() {
        let engine = self.engine
        // For now the log goes to the Terminal the app was started from.
        engine.onLog = { line in
            print(line)
            fflush(stdout)
        }
        engine.onStatus = { [weak self, weak engine] status in
            Task { @MainActor in
                // A stopped engine's last status is not wanted once a new engine has replaced it.
                guard let self, let engine, self.engine === engine else { return }
                self.status = status
            }
        }
        engine.start()
    }

    /// Saves new settings and restarts the engine with them.
    func apply(_ saved: SavedSettings) {
        saved.save()
        engine.stop()
        engine = BridgeEngine(settings: Self.settings(saved, overrides: portOverrides))
        status = BridgeStatus()
        start()
    }

    /// Makes `output` the home submix and remembers it. The output Main Out is assigned to is
    /// saved as "follow Main Out", so a later change of Main Out in TotalMix moves the home too.
    func setHomeSubmix(_ output: Int) {
        let followsMainOut = status.monitoringOutputs.first { $0.roles.contains(.mainOut) }?.output == output
        if followsMainOut {
            UserDefaults.standard.removeObject(forKey: Self.homeSubmixKey)
            engine.setHomeSubmix(nil)
        } else {
            UserDefaults.standard.set(output, forKey: Self.homeSubmixKey)
            engine.setHomeSubmix(output)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: BridgeModel
    /// Whether the home submix menu offers every output, not only the monitoring outputs.
    @AppStorage("showAllOutputs") private var showAllOutputs = false
    /// Whether the first playback starts a new page on the surfaces.
    @AppStorage("playbacksOnNewPage") private var playbacksOnNewPage = false

    private var totalMixState: String {
        let status = model.status
        if status.totalMixAnswering { return "connected" }
        if !status.listening { return "port \(model.engine.settings.endpoint.outgoingPort) in use, retrying" }
        return "no answer"
    }

    private var rotoState: String {
        let status = model.status
        if status.rotoConnected { return "connected" }
        if status.rotoFound { return "connecting" }
        return "not found, retrying"
    }

    var body: some View {
        // Short lines: a menu cuts long ones in the middle. The full reasons go to the log.
        Text("TotalMix FX: " + totalMixState)
        Text("Roto-Control: " + rotoState)
        Divider()
        Menu("Home submix") {
            ForEach(model.status.monitoringOutputs, id: \.output) { choice in
                Button(label(for: choice)) { model.setHomeSubmix(choice.output) }
            }
            if model.status.monitoringOutputs.isEmpty {
                Text("No monitoring outputs yet")
            }
            if showAllOutputs && !model.status.otherOutputs.isEmpty {
                Divider()
                Menu("Other outputs") {
                    ForEach(model.status.otherOutputs, id: \.output) { choice in
                        Button(label(for: choice)) { model.setHomeSubmix(choice.output) }
                    }
                }
            }
            Divider()
            Toggle("Show all outputs", isOn: $showAllOutputs)
        }
        Toggle("Playbacks start on a new page", isOn: Binding(
            get: { playbacksOnNewPage },
            set: { on in
                playbacksOnNewPage = on
                model.engine.setPlaybacksOnNewPage(on)
            }))
        Button("Ask TotalMix FX for its state") { model.engine.refresh() }
        Divider()
        Button("About Performance Bridge") {
            Windows.show("about", title: "About Performance Bridge") { AboutView() }
        }
        Button("Settings…") {
            Windows.show("settings", title: "Performance Bridge Settings") { SettingsView(model: model) }
        }
        .keyboardShortcut(",")
        Button("Quit Performance Bridge") {
            model.engine.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func label(for choice: HomeChoice) -> String {
        let mark = choice.output == model.status.homeSubmix ? "✓ " : "    "
        let roles = choice.roles.map(roleName).joined(separator: ", ")
        return roles.isEmpty ? "\(mark)\(choice.name)" : "\(mark)\(choice.name) (\(roles))"
    }

    private func roleName(_ role: MonitoringRole) -> String {
        switch role {
        case .mainOut: return "Main Out"
        case .mainOutB: return "Main Out B"
        case .phones1: return "Phones 1"
        case .phones2: return "Phones 2"
        case .phones3: return "Phones 3"
        case .phones4: return "Phones 4"
        case .cue: return "Cue"
        }
    }
}
