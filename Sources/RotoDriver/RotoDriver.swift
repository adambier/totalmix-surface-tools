import Foundation
#if canImport(OSCCodec)
import OSCCodec
#endif
#if canImport(TotalMixOSC)
import TotalMixOSC
#endif
#if canImport(RotoControl)
import RotoControl
#endif
#if canImport(SurfaceCore)
import SurfaceCore
#endif

/// What the Roto-Control driver produces in answer to MIDI from the Roto-Control: MIDI bytes for
/// the Roto-Control, and the core's output for TotalMix and the other surfaces.
public struct RotoStep: Equatable, Sendable {
    /// Complete MIDI messages for the Roto-Control, in order.
    public var midi: [UInt8] = []
    /// Messages for TotalMix, and updates for the other surfaces. This driver's own updates are
    /// already turned into `midi`.
    public var core = CoreOutput()

    /// Nothing to send.
    public init() {}
}

/// The driver for Melbourne Instruments' Roto-Control, in MIX mode, on top of `SurfaceHub`.
///
/// The driver does no input or output. The app passes it the bytes from the Roto-Control's MIDI
/// port with `receive(_:hub:now:)` and sends on what comes back; it passes the hub's updates for
/// this surface to `render(_:hub:now:)` and sends the bytes to the Roto-Control.
///
/// How the Roto-Control's MIX mode maps onto the core (docs/ROTO-CONTROL.md):
/// - the audio track set is the sources view, and the master and return set the outputs view;
/// - the level, pan, and send knob modes are the core's `level`, `pan`, and `send(n)`;
/// - the mute switch mode is mute; solo is PFL, as TotalMix's own Solo button is in its Live Mode
///   (docs/TOTALMIX-OSC.md, test 6); the record-arm switches do nothing (arming tracks in a DAW is planned for a later version; the
///   Roto-Control's firmware still shows their "ARM REC" label);
/// - single-track mode is the core's focus mode on the selected track: level, pan, and six sends
///   on page 0, and eight sends on each later page.
///
/// The driver claims to be Bitwig (`02`), as test 3 recommends: no 0 dB indent at the wrong
/// place, and switches that send only presses.
public struct RotoDriver: Sendable {
    /// What the Roto-Control has, for `SurfaceHub.addSurface`. The jump guard is 8,000 of the
    /// knob's 16,384 counts. In the kept logs of tests 2 and 3, counted by script, every end event
    /// in MIX mode jumped at least 12,690 counts, and no other report in MIX mode differed from the
    /// knob's last by more than 2,942 (docs/ROTO-CONTROL.md, section 6).
    public static let capabilities = SurfaceCapabilities(stripCount: RotoCC.controlCount, feel: .follows,
                                                         hasSwitches: true, hasMeters: true,
                                                         jumpGuard: 8000.0 / Double(RotoSysEx.maximum14Bit))

    /// The meter thresholds sent on connecting: yellow from `MeterScale.warning` (−5 dBFS) and red
    /// from `MeterScale.red` (−1 dBFS). The Roto-Control has been observed to show red at the red
    /// threshold itself, not only above it (docs/ROTO-CONTROL.md, test 4).
    public static let meterThresholds = (yellow: UInt8(MeterScale.warning), red: UInt8(MeterScale.red))

    /// Where the Roto-Control's 0 dB indent sits on a level or send knob (0…1) for each claimed host
    /// type, or `nil` where it is not known.
    /// - Bitwig (`02`): about 0.794, felt at "-0.8 dB" on a TotalMix fader (docs/ROTO-CONTROL.md,
    ///   section 3). The exact value, 0.5 raised to 1/3, is Bitwig's 0 dB on a volume law of twice
    ///   the cube of the position: an inference, from memory of Bitwig, not from Melbourne
    ///   Instruments' code or a measurement.
    /// - Ableton (`01`): 13926 of 16383, where the Roto-Control reported landing in it (test 3).
    public static func unityIndent(for hostType: RotoHostType) -> Double? {
        switch hostType {
        case .bitwig: return pow(0.5, 1.0 / 3.0)
        case .ableton: return 13926.0 / Double(RotoSysEx.maximum14Bit)
        case .logic: return nil
        }
    }

    /// The knob position (0…1) for a fader position (0…1), bent so that TotalMix's 0 dB
    /// (`FaderCurve.unityPosition`) lands in the knob's 0 dB indent: linear from 0 to the indent
    /// and from the indent to 1. With no indent, the position is unchanged.
    public static func knobPosition(forFader fader: Double, indent: Double?) -> Double {
        let fader = min(max(fader, 0), 1)
        guard let indent, indent > 0, indent < 1 else { return fader }
        let unity = FaderCurve.unityPosition
        if fader <= unity { return fader / unity * indent }
        return indent + (fader - unity) / (1 - unity) * (1 - indent)
    }

    /// The fader position (0…1) for a knob position (0…1): the inverse of
    /// `knobPosition(forFader:indent:)`.
    public static func faderPosition(forKnob knob: Double, indent: Double?) -> Double {
        let knob = min(max(knob, 0), 1)
        guard let indent, indent > 0, indent < 1 else { return knob }
        let unity = FaderCurve.unityPosition
        if knob <= indent { return knob / indent * unity }
        return unity + (knob - indent) / (1 - indent) * (1 - unity)
    }

    /// The surface's name in the hub.
    public let id: SurfaceID
    private var handshake: RotoHandshake
    private let indent: Double?
    private var decoder = RotoInputDecoder()
    private var inPluginMode = false
    private var selectedTrack = 0
    private var trackSet: RotoTrackSet = .audio
    private var infos: [StripInfo?] = Array(repeating: nil, count: RotoCC.controlCount)
    private var page = (first: 0, count: 0)
    private var motorTargets: [(position: Int, time: Double)?] = Array(repeating: nil, count: RotoCC.controlCount)

    /// How long after the driver moves a knob its reports are ignored, in seconds, while the motor
    /// travels. On connecting, knobs the driver had just moved have been observed to report
    /// positions near their new ones for about 0.6 s, which a host would otherwise pass on as the
    /// user's turns (docs/ROTO-CONTROL.md, test 4; that the motor caused them is an inference).
    public static let motorSettleTime: Double = 0.75
    /// For a while longer, reports this close to where the driver put the knob (in counts of
    /// 16,383) are taken as the motor settling, not the user.
    public static let motorJitter = 200
    /// How long the closeness rule lasts after the driver moves a knob, in seconds.
    public static let motorJitterTime: Double = 2

    /// A driver for one Roto-Control, which will claim `hostType` (Bitwig by default).
    public init(id: SurfaceID, hostType: RotoHostType = .bitwig) {
        self.id = id
        handshake = RotoHandshake(hostType: hostType)
        indent = Self.unityIndent(for: hostType)
    }

    /// Whether the handshake is complete.
    public var isConnected: Bool { handshake.isConnected }

    /// A test of exact colors (SET TRACK COLOUR), off (`nil`) by default: RGB colors by TotalMix
    /// color index, sent for every strip of the page each time a page is drawn in all-tracks mode,
    /// after the color schemes. The Roto-Control draws the names in white over an exact color, and
    /// has been observed to keep an exact color on its screen when the page changes
    /// (docs/ROTO-CONTROL.md, test 4), so every strip gets one.
    public var exactColors: [Int: RotoColor]?

    /// The exact colors for the strips of the current page in all-tracks mode, or nothing when
    /// `exactColors` is off. SET TRACK COLOUR's index is taken to be the screen (0–7), not the
    /// track: an inference from test 4, where colors sent with indexes 0–7 showed on that screen
    /// and stayed there when the page changed (runs 14 and 15), and every color sent with an index
    /// of 8 or more was followed by the Roto-Control freezing (runs 15, 17, and 18). Every strip
    /// gets a color, because a color stays on its screen; blank screens get none.
    private func exactColorMessages(onlyTotalMixColor color: Int? = nil) -> [RotoOutgoing] {
        guard let palette = exactColors else { return [] }
        return infos.enumerated().compactMap { offset, info in
            guard let info, page.first + offset < page.count else { return nil }
            if let color, !(info.kind == .source && info.color == color) { return nil }
            return .trackColor(index: offset, Self.exactColor(for: info, palette: palette))
        }
    }

    /// Color schemes chosen in place of `schemeForTotalMixColor`, by TotalMix color index, for
    /// strips drawn in their TotalMix color: for trying schemes on the screens. Empty by default.
    public var schemeOverrides: [Int: UInt8] = [:]

    /// The color scheme this driver draws a strip with: an override for a source's TotalMix
    /// color if there is one, else `colorScheme(for:)`.
    public func scheme(for info: StripInfo) -> UInt8 {
        if info.kind == .source || Self.hasColor(info), let color = info.color, let scheme = schemeOverrides[color] {
            return scheme
        }
        return Self.colorScheme(for: info)
    }

    /// SET TRACK DETAILS (shown at once) for the sources on the current page in TotalMix color
    /// `color`: one message per strip, for trying color schemes without drawing the whole page,
    /// which in quick succession has been followed by the Roto-Control freezing (run 19; that the
    /// redraws caused it is an inference). Nothing outside all-tracks mode or before the handshake.
    public func immediateDetails(forTotalMixColor color: Int, hub: SurfaceHub) -> [UInt8] {
        guard handshake.isConnected, !inPluginMode, case .strips? = hub.mode(of: id) else { return [] }
        return infos.enumerated().compactMap { offset, info -> RotoOutgoing? in
            guard let info, info.kind == .source, info.color == color else { return nil }
            return .trackDetails(RotoTrackDetails(index: page.first + offset, name: info.name,
                                                  colorScheme: scheme(for: info)), immediate: true)
        }.flatMap(\.bytes)
    }

    /// The current page drawn with its first screens as swatches, each named "scheme N" in color
    /// scheme N, to compare schemes side by side; the other screens keep their strips. Drawn as a
    /// page is (TRACK DETAILS … END), because SET TRACK DETAILS has been observed to change a
    /// screen's name but not its color (run 22). Screens past the last track are skipped. Nothing
    /// outside all-tracks mode or before the handshake.
    public func swatchBytes(_ schemes: [UInt8], hub: SurfaceHub) -> [UInt8] {
        guard handshake.isConnected, !inPluginMode, case .strips? = hub.mode(of: id) else { return [] }
        var messages: [RotoOutgoing] = [.trackCount(page.count), .firstTrack(page.first)]
        for (offset, info) in infos.enumerated() where page.first + offset < page.count {
            if offset < schemes.count {
                messages.append(.trackDetails(RotoTrackDetails(index: page.first + offset, name: "scheme \(schemes[offset])",
                                                               colorScheme: schemes[offset]), immediate: false))
            } else if let info {
                messages.append(.trackDetails(RotoTrackDetails(index: page.first + offset, name: info.name,
                                                               colorScheme: scheme(for: info)), immediate: false))
            }
        }
        messages.append(.trackDetailsEnd)
        return messages.flatMap(\.bytes)
    }

    /// The bytes that set the exact colors of the current page again, without drawing the strips:
    /// for changing a color while watching the screens. Nothing before the handshake is complete,
    /// in PLUGIN mode or single-track mode, or when `exactColors` is off.
    /// With `color`, only for the sources in that TotalMix color.
    public func exactColorBytes(hub: SurfaceHub, onlyTotalMixColor color: Int? = nil) -> [UInt8] {
        guard handshake.isConnected, !inPluginMode, case .strips? = hub.mode(of: id) else { return [] }
        return exactColorMessages(onlyTotalMixColor: color).flatMap(\.bytes)
    }

    /// The bytes that draw the current page again, or nothing before the handshake is complete or
    /// in PLUGIN mode. For trying color settings without changing the page.
    public func redraw(hub: SurfaceHub) -> [UInt8] {
        guard handshake.isConnected, !inPluginMode else { return [] }
        return pageMessages(hub: hub).flatMap(\.bytes)
    }

    /// How often DAW STARTED is sent again while the handshake is not complete, in seconds. The
    /// Roto-Control has been observed once not to answer DAW STARTED until it was plugged in again
    /// (docs/ROTO-CONTROL.md, test 4, run 15); whether a later DAW STARTED would have been answered
    /// is not known.
    public static let restartInterval: Double = 3

    private var lastStart: Double?

    /// Starts, or restarts, the handshake: the bytes to send now. `tick(now:)` sends DAW STARTED
    /// again every `restartInterval` until the Roto-Control connects.
    public mutating func start(now: Double = 0) -> [UInt8] {
        lastStart = now
        return handshake.start().flatMap(\.bytes)
    }

    /// The bytes to send as time passes: DAW STARTED again, if the handshake was started and has
    /// not completed within `restartInterval`. The app calls this regularly, with the current time.
    public mutating func tick(now: Double) -> [UInt8] {
        guard !handshake.isConnected, let lastStart, now - lastStart >= Self.restartInterval else { return [] }
        return start(now: now)
    }

    // MARK: - From the Roto-Control

    /// Takes bytes from the Roto-Control's MIDI port, as they arrive.
    public mutating func receive<S: Sequence>(_ bytes: S, hub: inout SurfaceHub, now: Double) -> RotoStep
    where S.Element == UInt8 {
        var step = RotoStep()
        for input in decoder.feed(bytes) {
            switch input {
            case .message(let message): handle(message, hub: &hub, now: now, into: &step)
            case .control(let event): handle(event, hub: &hub, now: now, into: &step)
            }
        }
        return step
    }

    private mutating func handle(_ message: RotoIncoming, hub: inout SurfaceHub, now: Double, into step: inout RotoStep) {
        let (reply, justConnected) = handshake.handle(message)
        step.midi += reply.flatMap(\.bytes)
        // A ping means the handshake is moving: the retry waits a full interval from here.
        if case .pingDAW = message, lastStart != nil { lastStart = now }
        if justConnected {
            inPluginMode = false
            let thresholds = Self.meterThresholds
            step.midi += RotoOutgoing.meterThresholds(yellow: thresholds.yellow, red: thresholds.red).bytes
            take(hub.resend(id, now: now), hub: hub, now: now, into: &step)
            return
        }
        guard handshake.isConnected else { return }

        switch message {
        case .pluginMode:
            // PLUGIN mode is not driven yet. The answer is the start of the sequence `sbdev roto`
            // sent in tests 2 and 3, with no plugins; that it settles the Roto-Control with no
            // plugins is an inference, still to be tested.
            inPluginMode = true
            step.midi += [RotoOutgoing.pluginCount(0), .firstPlugin(0), .pluginDetailsEnd].flatMap(\.bytes)
        case .allTracksMode(let mode):
            inPluginMode = false
            trackSet = mode.trackSet
            let next = SurfaceMode.strips(view: Self.view(mode.trackSet), first: firstIfSameView(hub, mode.trackSet),
                                          knob: Self.knobFunction(mode), switch: Self.switchFunction(mode.switchMode))
            take(hub.setMode(id, next, now: now), hub: hub, now: now, into: &step)
        case .trackSet(let set):
            trackSet = set
            selectedTrack = 0
            guard case .strips(_, _, let knob, let switchFunction)? = hub.mode(of: id) else { return }
            take(hub.setMode(id, .strips(view: Self.view(set), first: 0, knob: knob, switch: switchFunction), now: now),
                 hub: hub, now: now, into: &step)
        case .setFirstTrack(let first):
            guard case .strips(let view, _, let knob, let switchFunction)? = hub.mode(of: id) else { return }
            take(hub.setMode(id, .strips(view: view, first: first, knob: knob, switch: switchFunction), now: now),
                 hub: hub, now: now, into: &step)
        case .selectTrack(let index):
            selectedTrack = index
            if case .focus(_, let first)? = hub.mode(of: id), let channel = channel(at: index, hub: hub) {
                take(hub.setMode(id, .focus(channel: channel, first: first), now: now), hub: hub, now: now, into: &step)
            }
        case .singleTrackMode(let controlPage):
            inPluginMode = false
            // Test 2: the Roto-Control numbers these pages 0, 1, 2. Page 0 holds level, pan, and
            // sends 1–6; each later page eight sends, so page p starts at the core's slot 8p.
            guard let channel = channel(at: selectedTrack, hub: hub) ?? channel(at: 0, hub: hub) else { return }
            take(hub.setMode(id, .focus(channel: channel, first: max(controlPage, 0) * 8), now: now),
                 hub: hub, now: now, into: &step)
        case .requestSendNames(let sendIndex):
            step.midi += sendNames(start: RotoOutgoing.sendNamesStart(forSendIndex: sendIndex), hub: hub).bytes
        case .requestTransportStatus:
            step.midi += RotoOutgoing.transportStatus(RotoTransportStatus()).bytes
        default:
            break
        }
    }

    private mutating func handle(_ event: RotoControlEvent, hub: inout SurfaceHub, now: Double, into step: inout RotoStep) {
        guard handshake.isConnected, !inPluginMode else { return }
        switch event {
        case .knob(let index, let position):
            if Self.isMotor(report: position, target: motorTargets.indices.contains(index) ? motorTargets[index] : nil, now: now) {
                return
            }
            var value = RotoFeedback.fraction(position)
            if isLevel(index, hub: hub) { value = Self.faderPosition(forKnob: value, indent: indent) }
            take(hub.controlMoved(id, strip: index, to: value, now: now), hub: hub, now: now, into: &step)
        case .touch(let index, let touched):
            take(hub.touched(id, strip: index, touched, now: now), hub: hub, now: now, into: &step)
        case .switch(let index, let value):
            // Type 02: 127 on a press, nothing on release (docs/ROTO-CONTROL.md, section 5).
            guard value >= 64 else { return }
            take(hub.switchPressed(id, strip: index, now: now), hub: hub, now: now, into: &step)
        case .transport, .levelToZeroDB, .otherCC:
            break
        }
    }

    /// Moves this surface's updates out of a core output and into MIDI.
    private mutating func take(_ output: CoreOutput, hub: SurfaceHub, now: Double, into step: inout RotoStep) {
        var output = output
        if let own = output.updates.removeValue(forKey: id) {
            step.midi += render(own, hub: hub, now: now)
        }
        step.core.append(output)
    }

    // MARK: - To the Roto-Control

    /// Turns the hub's updates for this surface into MIDI for the Roto-Control. Returns nothing
    /// before the handshake is complete, or in PLUGIN mode.
    public mutating func render(_ updates: [SurfaceUpdate], hub: SurfaceHub, now: Double) -> [UInt8] {
        guard handshake.isConnected, !inPluginMode, !updates.isEmpty else { return [] }
        var pageChanged = false
        var controls: [UInt8] = []
        for update in updates {
            switch update {
            case .page(let first, let count):
                page = (first, count)
                pageChanged = true
            case .strip(let index, let info):
                guard infos.indices.contains(index) else { continue }
                infos[index] = info
                pageChanged = true
            case .knob(let index, let value):
                guard var value else { continue }
                if isLevel(index, hub: hub) { value = Self.knobPosition(forFader: value, indent: indent) }
                let position = RotoFeedback.position(value)
                if motorTargets.indices.contains(index) { motorTargets[index] = (position, now) }
                controls += RotoFeedback.knob(index, position: position)
            case .valueText(let index, let text):
                controls += RotoOutgoing.showValue(.knob, control: index, text: text).bytes
            case .switchState(let index, let on):
                controls += RotoFeedback.switchLight(index, on: on)
            case .meter(let index, let value):
                let level = UInt8(min(max(value, 0), 127))
                controls += RotoFeedback.meter(index, left: level, right: level)
            }
        }
        guard pageChanged else { return controls }
        return pageMessages(hub: hub).flatMap(\.bytes) + controls
    }

    /// The messages that draw the current page: in all-tracks mode the send names and the eight
    /// strips (TRACK DETAILS END draws them; blank strips are reset); in single-track mode the send
    /// names and DAW SELECT TRACK, which draws the send labels (docs/ROTO-CONTROL.md, section 4).
    private func pageMessages(hub: SurfaceHub) -> [RotoOutgoing] {
        let sendCount = hub.sendTargets.count
        switch hub.mode(of: id) {
        case .focus(let channel, let first)?:
            let controlPage = first / 8
            let start = RotoOutgoing.sendNamesStart(forControlPage: controlPage, numbering: .pageNumbers)
            let info = infos.compactMap { $0 }.first
            let details = RotoTrackDetails(index: max(selectedTrack, 0), name: info?.name ?? channel.description,
                                           colorScheme: info.map(scheme(for:)) ?? 0)
            return [.sendCount(sendCount), sendNames(start: start, hub: hub), .selectTrack(details)]
        case .strips(_, _, let knob, _)?:
            // The send names go out in every knob mode: the Roto-Control shows them while SEL is
            // held, and has been observed to keep names from an earlier session (2026-10-30).
            var sendIndex = 0
            if case .send(let index) = knob { sendIndex = index }
            var messages: [RotoOutgoing] = [.sendCount(sendCount),
                                            sendNames(start: RotoOutgoing.sendNamesStart(forSendIndex: sendIndex), hub: hub)]
            messages += [.trackCount(page.count), .firstTrack(page.first)]
            for (offset, info) in infos.enumerated() {
                guard let info else { continue }
                messages.append(.trackDetails(RotoTrackDetails(index: page.first + offset, name: info.name,
                                                               colorScheme: scheme(for: info)),
                                              immediate: false))
            }
            messages.append(.trackDetailsEnd)
            for (offset, info) in infos.enumerated() where info == nil {
                messages.append(.resetTrackDetails(page.first + offset))
            }
            return messages + exactColorMessages()
        case nil:
            return []
        }
    }

    private func sendNames(start: Int, hub: SurfaceHub) -> RotoOutgoing {
        let targets = hub.sendTargets
        let names = (start..<max(start, min(start + 8, targets.count))).map { index -> String in
            let ref = ChannelRef(.output, targets[index])
            return Self.sendLabel(hub.mirror.channels[ref]?.name ?? ref.description)
        }
        return .sendNames(start: start, names: names)
    }

    /// The label for a send knob: the output's name marked as a destination, so that it does not
    /// read as that channel's own level. "to ADI-2" if it fits the Roto-Control's 12 characters,
    /// else "> ADI-2 +6dB", else ">" and the name, cut to fit.
    public static func sendLabel(_ name: String) -> String {
        let limit = RotoSysEx.nameFieldLength - 1
        for prefix in ["to ", "> "] where prefix.count + name.count <= limit {
            return prefix + name
        }
        return String((">" + name).prefix(limit))
    }

    // MARK: - Mapping

    /// The core's view for a Roto-Control track set.
    public static func view(_ set: RotoTrackSet) -> ViewKind {
        set == .audio ? .sources : .outputs
    }

    /// The core's knob function for a Roto-Control knob mode.
    public static func knobFunction(_ mode: RotoAllTracksMode) -> KnobFunction {
        switch mode.knobMode {
        case .level: return .level
        case .pan: return .pan
        case .send: return .send(mode.sendIndex)
        }
    }

    /// The core's switch function for a Roto-Control switch mode: solo is PFL, and record arm does
    /// nothing for now.
    public static func switchFunction(_ mode: RotoSwitchMode) -> SwitchFunction {
        switch mode {
        case .mute: return .mute
        case .solo: return .pfl
        case .arm: return .none
        }
    }

    /// The color scheme for monitoring outputs left white (TotalMix's default): 33, seen as green
    /// (docs/ROTO-CONTROL.md, test 2).
    public static let monitoringScheme: UInt8 = 33
    /// The color scheme for sends left white (TotalMix's default): 22, seen as blue.
    public static let sendScheme: UInt8 = 22

    /// Whether a strip has a TotalMix color other than the default white.
    private static func hasColor(_ info: StripInfo) -> Bool {
        guard let color = info.color else { return false }
        return color != 1 && schemeForTotalMixColor[color] != nil
    }

    /// The Roto-Control color scheme for a strip: its TotalMix color; for an output left white
    /// (TotalMix's default), its kind instead: monitoring outputs green, sends blue (Adam,
    /// 2026-10-30).
    public static func colorScheme(for info: StripInfo) -> UInt8 {
        switch info.kind {
        case .monitoring where !hasColor(info): return monitoringScheme
        case .send where !hasColor(info): return sendScheme
        default: return colorScheme(forTotalMixColor: info.color)
        }
    }

    /// The Roto-Control color scheme for each of TotalMix's eight colors, by TotalMix's color
    /// index: 1 white, 2 grey, 3 orange, 4 red, 5 blue, 6 green, 7 yellow, 8 pink (the order of
    /// TotalMix's Color menu, and the indexes TotalMix sends; docs/TOTALMIX-OSC.md, test 7). The
    /// schemes are matched by eye on the Roto-Control's screens to the colors TotalMix draws ("pink"
    /// is drawn purple), because the screens show some of the SysEx doc's table colors differently:
    /// darker reds and oranges look brown, and purples look royal blue (docs/ROTO-CONTROL.md,
    /// test 4). White is TotalMix's default; it is drawn as light grey (27, chosen by Adam from the
    /// neutral greys, run 24). Exact colors (SET TRACK COLOUR) are not used: they have been
    /// observed to show only on the first page and to stay on a screen when the page changes.
    public static let schemeForTotalMixColor: [Int: UInt8] = [
        1: 27,  // white (default), drawn light grey
        2: 49,  // grey
        3: 1,   // orange
        4: 14,  // red
        5: 9,   // blue
        6: 19,  // green, drawn lime
        7: 73,  // yellow, drawn yellow-orange (73 is too green, "banana"; nothing in the table is closer, run 23)
        8: 67,  // pink, drawn purple
    ]

    /// TotalMix's eight colors as RGB, for the exact-color test, by TotalMix color index: the
    /// accent line under a channel's name, sampled from a screenshot of TotalMix FX 2.10 on macOS
    /// (playback channels colored 1–8, 2026-10-30). White is TotalMix's default and draws no
    /// line; its value here, a light grey, is a placeholder, not a sample.
    public static let totalMixColors: [Int: RotoColor] = [
        1: RotoColor(red: 0xA0, green: 0xA4, blue: 0xA8),  // white: placeholder
        2: RotoColor(red: 0x61, green: 0x6E, blue: 0x7A),  // grey
        3: RotoColor(red: 0xA3, green: 0x5E, blue: 0x36),  // orange
        4: RotoColor(red: 0xBC, green: 0x39, blue: 0x34),  // red
        5: RotoColor(red: 0x38, green: 0x6A, blue: 0xA4),  // blue
        6: RotoColor(red: 0x4A, green: 0x96, blue: 0x43),  // green
        7: RotoColor(red: 0xE2, green: 0xB2, blue: 0x4A),  // yellow
        8: RotoColor(red: 0x6F, green: 0x41, blue: 0xCD),  // pink, drawn purple
    ]

    /// The exact color for a strip in the exact-color test: sources by their TotalMix color,
    /// monitoring outputs as TotalMix's green and sends as its blue (as the schemes show them), and
    /// white for no color or an index the palette lacks.
    public static func exactColor(for info: StripInfo, palette: [Int: RotoColor]) -> RotoColor {
        let index: Int?
        switch info.kind {
        case .monitoring: index = 6
        case .send: index = 5
        case .source: index = info.color
        }
        return index.flatMap { palette[$0] } ?? palette[1] ?? RotoColor(red: 0, green: 0, blue: 0)
    }

    /// The Roto-Control color scheme (0–82) for a TotalMix color index, or white (TotalMix's
    /// default) for no color or an unknown index.
    public static func colorScheme(forTotalMixColor color: Int?) -> UInt8 {
        guard let color, let scheme = schemeForTotalMixColor[color] else { return schemeForTotalMixColor[1] ?? 0 }
        return scheme
    }

    /// Whether a knob report is the motor settling after the driver moved the knob, rather than
    /// the user: within `motorSettleTime` of the move, or within `motorJitterTime` and
    /// `motorJitter` counts of where the knob was sent.
    public static func isMotor(report position: Int, target: (position: Int, time: Double)?, now: Double) -> Bool {
        guard let target else { return false }
        let elapsed = now - target.time
        if elapsed < motorSettleTime { return true }
        return elapsed < motorJitterTime && abs(position - target.position) <= motorJitter
    }

    /// Whether a strip's knob is a level or a send (a fader position), whose scale is bent to the
    /// indent; pans are not.
    private func isLevel(_ index: Int, hub: SurfaceHub) -> Bool {
        guard let strips = hub.strips(of: id), strips.indices.contains(index),
              case .level? = strips[index].knobTarget else { return false }
        return true
    }

    private func channel(at index: Int, hub: SurfaceHub) -> ChannelRef? {
        hub.channel(at: index, of: Self.view(trackSet), on: id)
    }

    /// Keeps the page when only the knob or switch mode changed; starts at 0 on a new view.
    private func firstIfSameView(_ hub: SurfaceHub, _ set: RotoTrackSet) -> Int {
        if case .strips(let view, let first, _, _)? = hub.mode(of: id), view == Self.view(set) { return first }
        return 0
    }
}
