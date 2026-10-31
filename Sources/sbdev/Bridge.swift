// sbdev bridge: runs SurfaceCore and the Roto-Control driver between TotalMix and a Roto-Control,
// as the app will, for trying them on the hardware before the app exists.

import Foundation
import OSCCodec
import TotalMixOSC
import RotoControl
import MIDITransport
import UDPTransport
import SurfaceCore
import RotoDriver

let bridgeUsage = """
    Usage:
      sbdev bridge [--host H] [--in-port P] [--out-port P] [--port NAME] [--home N] [--verbose]
          Connects TotalMix and a Roto-Control through SurfaceCore and the Roto-Control driver,
          as the app will. Prints what is sent to TotalMix, the SysEx messages in both directions,
          and the names, colors, and control-room settings TotalMix sends, with the time since
          starting; --verbose also prints everything else TotalMix sends (not /level or
          /status) and every MIDI message to the Roto-Control. Then reads commands from the
          keyboard (type `help`).
          --host, --in-port, and --out-port are TotalMix's, as for monitor. --port names the
          Roto-Control's MIDI ports (default "Roto"). --home is the home submix's output number,
          counting from 1 as TotalMix's window does (default: TotalMix's Main Out).
          Meters need "Send Level Data" on in TotalMix's OSC settings. Stop sbdev monitor
          first: both need the outgoing port.
    """

let bridgeCommandHelp = """
    Commands:
      home N | home main   the home submix: output N (from 1), or TotalMix's Main Out
      solo on | solo off   allow or forbid solo on the switches (off at the start)
      menu TEXT            test: send SET CURRENT TRACK NAME with TEXT, to see where it shows
      color exact          test: exact colors (SET TRACK COLOUR) on every strip
      color table          back to the color schemes alone
      color N RRGGBB       test: set TotalMix color N (1-8) to an RGB color, and show exact colors
      color tune N         test: tune TotalMix color N with knobs 1-3 (hue, saturation,
                           brightness), watching the screens; the knobs leave the mixer alone
      color done           stop tuning: the knobs go back to the mixer
      color                list the exact colors
      scheme tune N        test: choose the color scheme (0-82) for TotalMix color N with knob 1,
                           watching the screens; the knobs leave the mixer alone
      scheme done          stop: the knobs go back to the mixer
      scheme N S           use scheme S for TotalMix color N
      scheme               list the schemes for TotalMix's colors
      swatch S S ...       test: show color schemes S side by side on the first screens
      swatch done          draw the strips again
      pbpage on | pbpage off   start the first playback on a new page, or not
      sendall              ask TotalMix for its state again
      status               the mode, the home submix, the send targets, and the strips
      quit
    """

struct BridgeOptions {
    var endpoint = TotalMixEndpoint.standard
    var portName = "Roto"
    var home: Int?
    var verbose = false
}

func parseBridgeOptions(_ arguments: ArraySlice<String>) -> BridgeOptions {
    var options = BridgeOptions()
    var rest = arguments
    func value(_ option: String) -> String {
        guard let text = rest.popFirst() else { fail("\(option) needs a value.\n\n\(bridgeUsage)") }
        return text
    }
    func port(_ option: String) -> UInt16 {
        guard let number = UInt16(value(option)), number > 0 else { fail("\(option) needs a port number.") }
        return number
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--host": options.endpoint.host = value(argument)
        case "--in-port": options.endpoint.incomingPort = port(argument)
        case "--out-port": options.endpoint.outgoingPort = port(argument)
        case "--port": options.portName = value(argument)
        case "--home":
            guard let number = Int(value(argument)), number >= 1 else { fail("--home needs an output number from 1.") }
            options.home = number - 1
        case "--verbose": options.verbose = true
        case "-h", "--help": print(bridgeUsage); exit(0)
        default: fail("Unknown option \(argument).\n\n\(bridgeUsage)")
        }
    }
    return options
}

/// The hub, the driver, and their connections. Every change happens with the lock held.
final class BridgeSession: @unchecked Sendable {
    private let options: BridgeOptions
    private let lock = NSLock()
    private let start = Date()
    private var hub = SurfaceHub()
    private var driver = RotoDriver(id: SurfaceID("roto"))
    private var socket: UDPSocket?
    private var midi: MIDIConnection?
    private var oscDecodeErrors = 0
    /// The TotalMix color being tuned with knobs 1–3, and its hue (0–360), saturation, and
    /// brightness (0–1).
    private var tuning: (index: Int, hsv: HSV)?
    /// The TotalMix color whose color scheme is being chosen with knob 1, and the scheme.
    private var schemeTuning: (index: Int, scheme: UInt8)?
    /// SET TRACK COLOUR messages waiting to go to the Roto-Control, one per `colorGap`. Paced since
    /// run 18, when the freezes were thought to come from bursts; they are now thought to have
    /// come from indexes past 7 (run 20), so the pacing is only a precaution.
    private var pendingColors: [[UInt8]] = []
    private var lastColorSend = 0.0
    private let colorGap = 0.05
    private var tuneDecoder = RotoControlDecoder()
    private var tuneChanged = false
    private var lastTuneSend = 0.0
    private var lastTuneLog = 0.0

    init(options: BridgeOptions) {
        self.options = options
    }

    private var now: Double { Date().timeIntervalSince(start) }

    func connect() {
        lock.lock()
        defer { lock.unlock() }
        do {
            socket = try UDPSocket(listeningOn: options.endpoint.outgoingPort)
            midi = try MIDIConnection(clientName: "sbdev bridge", sourceName: options.portName,
                                      destinationName: options.portName) { [weak self] bytes in
                self?.fromRoto(bytes)
            }
        } catch {
            fail("\(error)")
        }
        log("TotalMix at \(options.endpoint.host), sending to port \(options.endpoint.incomingPort), listening on \(options.endpoint.outgoingPort). Roto-Control: \"\(midi!.source.name)\". Type `help` for commands.")
        socket?.startReceiving { [weak self] bytes, _ in self?.fromTotalMix(bytes) }
        dispatch(hub.addSurface(driver.id, capabilities: RotoDriver.capabilities, now: now))
        if let home = options.home { dispatch(hub.setHomeSubmix(home, now: now)) }
        dispatch(hub.connect(now: now))
        sendToRoto(driver.start(now: now))

        let ticker = Thread { [weak self] in
            while let session = self {
                session.tick()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        ticker.name = "bridge tick"
        ticker.start()
    }

    // MARK: Input

    private func fromTotalMix(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard let packet = try? OSCPacket(decoding: bytes) else {
            oscDecodeErrors += 1
            return
        }
        for message in packet.messages {
            guard let event = TotalMixEvent(message) else { continue }
            let settingsChange: Bool
            if case .channel(_, _, let parameter, _) = event {
                settingsChange = ["name", "color", "stereo"].contains(parameter)
            } else {
                settingsChange = message.address.hasPrefix("/controlroom/")
            }
            if settingsChange || (options.verbose && !message.address.hasPrefix("/level") && !message.address.hasPrefix("/status")) {
                log("← TotalMix \(message.address) \(message.arguments.map(describe).joined(separator: " "))")
            }
            dispatch(hub.handle(event, now: now))
        }
    }

    private func fromRoto(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        if bytes.first == 0xF0, let message = RotoIncoming(sysEx: bytes) {
            log("← Roto \(describe(message))")
        }
        // Switches, transport switches, and anything else that is not a knob or a touch, for the
        // tests: a CC on channel 16 outside the knob (12–19, 44–51) and touch (52–59) blocks.
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0xBF {
                let controller = bytes[index + 1], value = bytes[index + 2]
                let knobOrTouch = (12...19).contains(controller) || (44...59).contains(controller)
                if !knobOrTouch { log("← Roto CC \(controller) = \(value)") }
                index += 3
            } else {
                index += 1
            }
        }
        let tuningActive = tuning != nil || schemeTuning != nil
        let step = driver.receive(tuningActive ? takeTuningKnobs(bytes) : bytes, hub: &hub, now: now)
        sendToRoto(step.midi)
        dispatch(step.core)
    }

    /// While tuning: takes the knob and touch CCs out of the bytes, uses knobs 1–3 for the color,
    /// and returns the rest for the driver.
    private func takeTuningKnobs(_ bytes: [UInt8]) -> [UInt8] {
        var hsv = tuning?.hsv ?? HSV(RotoColor(red: 0, green: 0, blue: 0))
        var rest: [UInt8] = []
        var at = 0
        while at < bytes.count {
            if bytes[at] == 0xBF, at + 2 < bytes.count, (12...19).contains(bytes[at + 1]) || (44...59).contains(bytes[at + 1]) {
                if case .knob(let knob, let position)? = tuneDecoder.decode(channel: RotoCC.channel, controller: bytes[at + 1], value: bytes[at + 2]) {
                    let fraction = RotoFeedback.fraction(position)
                    if let (index, scheme) = schemeTuning {
                        if knob == 0 {
                            let chosen = UInt8((fraction * 82).rounded())
                            if chosen != scheme { schemeTuning = (index, chosen); tuneChanged = true }
                        }
                        at += 3
                        continue
                    }
                    switch knob {
                    case 0: hsv.hue = fraction * 360
                    case 1: hsv.saturation = fraction
                    case 2: hsv.brightness = fraction
                    default: break
                    }
                    tuneChanged = true
                }
                at += 3
            } else {
                rest.append(bytes[at])
                at += 1
            }
        }
        if let index = tuning?.index { tuning = (index, hsv) }
        return rest
    }

    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        dispatch(hub.tick(now: now))
        let restart = driver.tick(now: now)
        if !restart.isEmpty {
            log("No answer from the Roto-Control yet; sending DAW STARTED again")
            sendToRoto(restart)
        }
        if !pendingColors.isEmpty, now - lastColorSend >= colorGap {
            lastColorSend = now
            sendToRoto(pendingColors.removeFirst(), paced: false)
        }
        if let (index, scheme) = schemeTuning, tuneChanged, now - lastTuneSend >= 0.25 {
            tuneChanged = false
            lastTuneSend = now
            driver.schemeOverrides[index] = scheme
            // One SET TRACK DETAILS per strip in this color, not the whole page: redrawing the page
            // every 100 ms was followed by a freeze (run 19).
            sendToRoto(driver.immediateDetails(forTotalMixColor: index, hub: hub), quiet: true)
            log("Scheme for \(index) \(colorNames[index - 1]): \(scheme)")
        }
        if let (index, hsv) = tuning, tuneChanged, now - lastTuneSend >= 0.05 {
            tuneChanged = false
            lastTuneSend = now
            var palette = driver.exactColors ?? RotoDriver.totalMixColors
            palette[index] = hsv.color
            driver.exactColors = palette
            sendToRoto(driver.exactColorBytes(hub: hub, onlyTotalMixColor: index), quiet: true)
            if now - lastTuneLog >= 0.5 {
                lastTuneLog = now
                log("Tuning \(index) \(colorNames[index - 1]): \(rgb(hsv.color)) \(hsv)")
            }
        }
    }

    /// The switch lights for the page, which also draw the switch labels on the lower halves of
    /// the screens: drawing the strips again blanks them (run 19), and a redraw sends no lights.
    private func switchLights() -> [UInt8] {
        let lights = (hub.resend(driver.id, now: now).updates[driver.id] ?? []).filter {
            if case .switchState = $0 { return true }
            return false
        }
        return driver.render(lights, hub: hub, now: now)
    }

    private func startSchemeTuning(_ index: Int) {
        tuning = nil
        let scheme = driver.schemeOverrides[index] ?? RotoDriver.schemeForTotalMixColor[index] ?? 0
        schemeTuning = (index, scheme)
        tuneDecoder = RotoControlDecoder()
        sendToRoto(RotoFeedback.knob(0, position: RotoFeedback.position(Double(scheme) / 82)))
        log("Choosing the scheme for \(index) \(colorNames[index - 1]) from \(scheme): turn knob 1. `scheme done` to stop.")
    }

    private func startTuning(_ index: Int) {
        schemeTuning = nil
        var palette = driver.exactColors ?? RotoDriver.totalMixColors
        let color = palette[index] ?? RotoColor(red: 0x80, green: 0x80, blue: 0x80)
        palette[index] = color
        driver.exactColors = palette
        let hsv = HSV(color)
        tuning = (index, hsv)
        tuneDecoder = RotoControlDecoder()
        sendToRoto(driver.redraw(hub: hub))
        sendToRoto(RotoFeedback.knob(0, position: RotoFeedback.position(hsv.hue / 360))
                   + RotoFeedback.knob(1, position: RotoFeedback.position(hsv.saturation))
                   + RotoFeedback.knob(2, position: RotoFeedback.position(hsv.brightness)))
        log("Tuning \(index) \(colorNames[index - 1]) from \(rgb(color)) \(hsv): knob 1 hue, knob 2 saturation, knob 3 brightness. `color done` to stop.")
    }

    // MARK: Output

    private func dispatch(_ output: CoreOutput) {
        for message in output.messages {
            do {
                try socket?.send(message.encoded(), to: options.endpoint.host, port: options.endpoint.incomingPort)
            } catch {
                log("Could not send \(message.address): \(error)")
            }
            log("→ TotalMix \(message.address) \(message.arguments.map(describe).joined(separator: " "))")
        }
        for (id, updates) in output.updates where id == driver.id {
            sendToRoto(driver.render(updates, hub: hub, now: now))
        }
    }

    private func sendToRoto(_ bytes: [UInt8], quiet: Bool = false, paced: Bool = true) {
        var bytes = bytes
        if paced {
            // SET TRACK COLOUR waits in `pendingColors`, to go one per `colorGap`.
            var rest: [UInt8] = []
            var at = 0
            while at < bytes.count {
                if bytes[at] == 0xF0, let end = bytes[at...].firstIndex(of: 0xF7) {
                    let message = Array(bytes[at...end])
                    if message.count > 6, message[5] == 0x0A, message[6] == 0x13 {
                        pendingColors.removeAll { $0.count > 8 && $0[7] == message[7] && $0[8] == message[8] }
                        pendingColors.append(message)
                    } else {
                        rest += message
                    }
                    at = end + 1
                } else {
                    rest.append(bytes[at])
                    at += 1
                }
            }
            bytes = rest
        }
        guard !bytes.isEmpty else { return }
        do {
            try midi?.send(bytes)
        } catch {
            log("Could not send to the Roto-Control: \(error)")
        }
        if quiet { return }
        if options.verbose {
            log("→ Roto \(hex(bytes))")
            return
        }
        // Every SysEx message to the Roto-Control, for the tests (CCs, which carry knobs, lights,
        // and meters, only with --verbose).
        var start: Int?
        for (index, byte) in bytes.enumerated() {
            if byte == 0xF0 { start = index }
            if byte == 0xF7, let first = start {
                log("→ Roto \(hex(Array(bytes[first...index])))")
                start = nil
            }
        }
    }

    private func log(_ text: String) {
        print(String(format: "%9.3f  ", now) + text)
        flushOutput()
    }

    // MARK: Commands

    /// Runs one command typed at the keyboard. Returns false for `quit`.
    func run(_ line: String) -> Bool {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first else { return true }
        lock.lock()
        defer { lock.unlock() }
        switch command {
        case "quit", "exit":
            return false
        case "help":
            print(bridgeCommandHelp)
        case "home":
            if words.count == 2, words[1] == "main" {
                dispatch(hub.setHomeSubmix(nil, now: now))
            } else if words.count == 2, let number = Int(words[1]), number >= 1 {
                dispatch(hub.setHomeSubmix(number - 1, now: now))
            } else {
                print("home N (an output, from 1) or home main")
            }
            log("Home submix: \(hub.homeSubmix.map { "output \($0 + 1)" } ?? "none yet")")
        case "solo":
            guard words.count == 2, words[1] == "on" || words[1] == "off" else {
                print("solo on or solo off")
                return true
            }
            dispatch(hub.setSoloEnabled(words[1] == "on", now: now))
        case "menu":
            // A test: where does SET CURRENT TRACK NAME show? (docs/ROTO-CONTROL.md, section 8)
            let text = words.dropFirst().joined(separator: " ")
            sendToRoto(RotoOutgoing.currentTrackName(text).bytes)
            log("→ Roto SET CURRENT TRACK NAME \"\(text)\"")
        case "color":
            // A test of exact colors: does resending all eight screens keep them from sticking,
            // and how do TotalMix's own colors look on the screens? (docs/ROTO-CONTROL.md, test 4)
            if words.count == 3, words[1] == "tune", let index = Int(words[2]), (1...8).contains(index) {
                startTuning(index)
                return true
            } else if words.count == 2, words[1] == "done" {
                if let (index, hsv) = tuning {
                    log("Tuned \(index) \(colorNames[index - 1]): \(rgb(hsv.color)) \(hsv)")
                }
                tuning = nil
                dispatch(hub.resend(driver.id, now: now))
            } else if words.count == 2, words[1] == "exact" {
                driver.exactColors = driver.exactColors ?? RotoDriver.totalMixColors
            } else if words.count == 2, words[1] == "table" {
                tuning = nil
                pendingColors.removeAll()
                driver.exactColors = nil
            } else if words.count == 3, let index = Int(words[1]), (1...8).contains(index),
                      let color = parseRGB(words[2]) {
                var palette = driver.exactColors ?? RotoDriver.totalMixColors
                palette[index] = color
                driver.exactColors = palette
            } else if words.count != 1 {
                print("color exact, color table, color N RRGGBB, color tune N (N from 1 to 8), color done, or color")
                return true
            }
            if words.count > 1, words[1] != "done" { sendToRoto(driver.redraw(hub: hub) + switchLights()) }
            if let palette = driver.exactColors {
                let list = (1...8).map { "\($0) \(colorNames[$0 - 1]) \(palette[$0].map(rgb) ?? "-")" }
                log("Exact colors: " + list.joined(separator: ", "))
            } else {
                log("Color schemes only (no exact colors)")
            }
        case "scheme":
            if words.count == 3, words[1] == "tune", let index = Int(words[2]), (1...8).contains(index) {
                startSchemeTuning(index)
                return true
            } else if words.count == 2, words[1] == "done" {
                schemeTuning = nil
                dispatch(hub.resend(driver.id, now: now))
            } else if words.count == 3, let index = Int(words[1]), (1...8).contains(index),
                      let scheme = UInt8(words[2]), scheme <= 82 {
                driver.schemeOverrides[index] = scheme
                sendToRoto(driver.immediateDetails(forTotalMixColor: index, hub: hub))
            } else if words.count != 1 {
                print("scheme tune N, scheme done, scheme N S (N from 1 to 8, S from 0 to 82), or scheme")
                return true
            }
            let list = (1...8).map { index -> String in
                let scheme = driver.schemeOverrides[index] ?? RotoDriver.schemeForTotalMixColor[index] ?? 0
                return "\(index) \(colorNames[index - 1]) \(scheme)"
            }
            log("Schemes: " + list.joined(separator: ", "))
        case "swatch":
            if words.count == 2, words[1] == "done" {
                dispatch(hub.resend(driver.id, now: now))
                return true
            }
            let schemes = words.dropFirst().compactMap { UInt8($0) }.filter { $0 <= 82 }
            guard !schemes.isEmpty, schemes.count == words.count - 1 else {
                print("swatch S S ... (schemes from 0 to 82, up to 8), or swatch done")
                return true
            }
            sendToRoto(driver.swatchBytes(schemes, hub: hub) + switchLights())
            log("Swatches on screens 1-\(min(schemes.count, 8)): schemes \(schemes.map(String.init).joined(separator: ", ")). `swatch done` to put the strips back.")
        case "pbpage":
            guard words.count == 2, words[1] == "on" || words[1] == "off" else {
                print("pbpage on or pbpage off")
                return true
            }
            var layout = hub.layout
            layout.playbacksOnNewPage = words[1] == "on"
            dispatch(hub.setLayout(layout, now: now))
            log("Playbacks on a new page: \(words[1])")
        case "sendall":
            dispatch(hub.connect(now: now))
        case "status":
            log("Mode: \(hub.mode(of: driver.id).map(describe) ?? "none"); connected: \(driver.isConnected)")
            log("Home submix: \(hub.homeSubmix.map { "output \($0 + 1)" } ?? "none yet"); send targets: \(hub.sendTargets.map { "output \($0 + 1)" })")
            for (index, strip) in (hub.strips(of: driver.id) ?? []).enumerated() {
                let name = strip.info.map { "\($0.name) (\($0.channel))" } ?? "blank"
                log("  strip \(index + 1): \(name); knob \(strip.knobTarget.map { "\($0)" } ?? "none"); switch \(strip.switchTarget.map { "\($0)" } ?? "none")")
            }
            if oscDecodeErrors > 0 { log("Packets from TotalMix that were not OSC: \(oscDecodeErrors)") }
        default:
            print("Unknown command. Type `help`.")
        }
        return true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        socket?.stop()
        midi?.close()
    }
}

/// A surface mode in words, e.g., "sources from 9, knobs level, switches mute".
func describe(_ mode: SurfaceMode) -> String {
    switch mode {
    case .strips(let view, let first, let knob, let switchFunction):
        let knobText: String
        switch knob {
        case .level: knobText = "level"
        case .pan: knobText = "pan"
        case .send(let index): knobText = "send \(index + 1)"
        }
        let switchText: String
        switch switchFunction {
        case .mute: switchText = "mute"
        case .pfl: switchText = "PFL"
        case .solo: switchText = "solo"
        case .none: switchText = "nothing"
        }
        return "\(view == .sources ? "sources" : "outputs") from \(first + 1), knobs \(knobText), switches \(switchText)"
    case .focus(let channel, let first):
        return "single track \(channel), from slot \(first + 1)"
    }
}

/// TotalMix's color names, by index from 1.
let colorNames = ["white", "grey", "orange", "red", "blue", "green", "yellow", "pink"]

/// A color as hue (0–360), saturation, and brightness (0–1), for tuning with knobs.
struct HSV: CustomStringConvertible {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(_ color: RotoColor) {
        let r = Double(color.red) / 255, g = Double(color.green) / 255, b = Double(color.blue) / 255
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        var hue = 0.0
        if range > 0 {
            if high == r { hue = 60 * ((g - b) / range).truncatingRemainder(dividingBy: 6) }
            else if high == g { hue = 60 * ((b - r) / range + 2) }
            else { hue = 60 * ((r - g) / range + 4) }
        }
        self.hue = hue < 0 ? hue + 360 : hue
        saturation = high > 0 ? range / high : 0
        brightness = high
    }

    var color: RotoColor {
        let chroma = brightness * saturation
        let sector = (hue.truncatingRemainder(dividingBy: 360)) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = brightness - chroma
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v + m, 0), 1) * 255).rounded()) }
        return RotoColor(red: byte(r), green: byte(g), blue: byte(b))
    }

    var description: String {
        String(format: "(hue %.0f, saturation %.2f, brightness %.2f)", hue, saturation, brightness)
    }
}

/// An RGB color from six hex digits, with or without a leading "#".
func parseRGB(_ text: String) -> RotoColor? {
    let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    return RotoColor(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
}

/// Six hex digits for an RGB color.
func rgb(_ color: RotoColor) -> String {
    String(format: "%02X%02X%02X", color.red, color.green, color.blue)
}

func bridge(_ arguments: ArraySlice<String>) -> Never {
    let session = BridgeSession(options: parseBridgeOptions(arguments))
    session.connect()
    var quit = false
    while let line = readLine() {
        if !session.run(line) { quit = true; break }
    }
    if !quit, isatty(fileno(stdin)) == 0 {
        while true { Thread.sleep(forTimeInterval: 60) }
    }
    session.close()
    exit(0)
}
