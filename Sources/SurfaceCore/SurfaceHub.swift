import Foundation
#if canImport(OSCCodec)
import OSCCodec
#endif
#if canImport(TotalMixOSC)
import TotalMixOSC
#endif

/// The surface-neutral core: TotalMix's state, the surfaces' strips, and the rules between them.
///
/// The hub does no input or output and reads no clock. The app passes in what TotalMix sends and
/// what the surfaces' drivers report, with the time in seconds, and sends on what each call
/// returns: messages for TotalMix and updates for each surface. The app also calls `tick(now:)`
/// often (e.g., every 10 ms), for thinned messages, meters, and controls let go.
public struct SurfaceHub: Sendable {
    /// The shortest time between two meter updates of one strip, in seconds (12 per second).
    public static let meterInterval: Double = 1.0 / 12
    /// How long to wait for TotalMix to answer `/sendall` before asking again, in seconds.
    /// TotalMix has been observed to leave a `/sendall` unanswered while still sending status
    /// messages (docs/TOTALMIX-OSC.md, test 1), so only a channel setting or a mixer node counts as
    /// an answer.
    public static let snapshotRetry: Double = 1

    /// The core's copy of TotalMix's state.
    public private(set) var mirror = MixerMirror()
    /// The channels and their order, as chosen in the app.
    public private(set) var layout: PerformanceLayout
    /// The home submix chosen in the app, or `nil` to follow the control room's Main Out.
    public private(set) var homeChoice: Int?
    /// Whether switches may be set to solo. Off by default: what TotalMix's solo does to the rest
    /// of a submix is unchecked, and in live use it could silence the audience's mix.
    public private(set) var soloEnabled = false

    private var surfaces: [SurfaceID: SurfaceState] = [:]
    private var order: [SurfaceID] = []
    private var thinner = OutgoingThinner()
    private var snapshotAskedAt: Double?

    /// A hub with no surfaces.
    public init(layout: PerformanceLayout = PerformanceLayout()) {
        self.layout = layout
    }

    /// The home submix: the output whose submix the level knobs and pans of sources control.
    /// The app's choice, or else the control room's Main Out; `nil` before TotalMix has sent it.
    public var homeSubmix: Int? { homeChoice ?? mirror.mainOut }

    /// The outputs the send knobs reach, in order: the outputs view's channels, minus the
    /// monitoring outputs (Main Out, Main Out B, Phones 1–4, and cue, as the control room assigns
    /// them) and the home submix. These are the feeds to other hardware. `send(0)` is the first.
    public var sendTargets: [Int] {
        let home = homeSubmix
        let monitoring = mirror.monitoringOutputs
        return layout.channels(.outputs, in: mirror).map(\.channel).filter { $0 != home && !monitoring.contains($0) }
    }

    /// The surfaces, in the order they were added.
    public var surfaceIDs: [SurfaceID] { order }

    /// A surface's mode, or `nil` for an unknown surface.
    public func mode(of id: SurfaceID) -> SurfaceMode? { surfaces[id]?.mode }

    // MARK: - TotalMix

    /// Asks TotalMix for everything it has (`/sendall`), asking again in `tick(now:)` until it
    /// answers.
    public mutating func connect(now: Double) -> CoreOutput {
        snapshotAskedAt = now
        var output = CoreOutput()
        output.messages.append(TotalMixCommand.sendAll())
        return output
    }

    /// Takes one message from TotalMix.
    public mutating func handle(_ event: TotalMixEvent, now: Double) -> CoreOutput {
        switch event {
        case .channel, .mix: snapshotAskedAt = nil
        default: break
        }
        guard let change = mirror.apply(event) else { return CoreOutput() }
        switch change {
        case .meter(let ref):
            return meterChanged(ref, now: now)
        case .node(let key):
            return refresh(where: { $0.contains(node: key) }, now: now)
        case .channel, .controlRoom:
            return refreshAll(now: now)
        }
    }

    /// Sends what is due: thinned messages, meters held back by the rate limit, the values of
    /// controls just let go, and a repeated `/sendall`.
    public mutating func tick(now: Double) -> CoreOutput {
        var output = CoreOutput()
        if let asked = snapshotAskedAt, now - asked >= Self.snapshotRetry {
            snapshotAskedAt = now
            output.messages.append(TotalMixCommand.sendAll())
        }
        output.messages += thinner.flush(now: now)
        for id in order {
            guard var state = surfaces[id] else { continue }
            for index in state.slots.indices {
                if let value = state.slots[index].meterPending,
                   now - (state.slots[index].meterSentAt ?? -.infinity) >= Self.meterInterval {
                    state.slots[index].meterPending = nil
                    state.slots[index].meterShown = value
                    state.slots[index].meterSentAt = now
                    output.add(.meter(index: index, value: value), for: id)
                }
            }
            var released = false
            for index in state.slots.indices where state.slots[index].wasHeld && !state.holds[index].isHeld(now: now) {
                state.slots[index].wasHeld = false
                released = true
            }
            surfaces[id] = state
            if released { output.append(render(id, force: false, now: now)) }
        }
        return output
    }

    // MARK: - Settings from the app

    /// Sets the home submix (an output channel), or `nil` to follow the control room's Main Out.
    public mutating func setHomeSubmix(_ output: Int?, now: Double) -> CoreOutput {
        homeChoice = output
        return refreshAll(now: now)
    }

    /// Sets the channels and their order.
    public mutating func setLayout(_ layout: PerformanceLayout, now: Double) -> CoreOutput {
        self.layout = layout
        return refreshAll(now: now)
    }

    /// Allows or forbids solo on the switches.
    public mutating func setSoloEnabled(_ enabled: Bool, now: Double) -> CoreOutput {
        soloEnabled = enabled
        return refreshAll(now: now)
    }

    // MARK: - Surfaces

    /// Adds a surface and returns everything it should show.
    public mutating func addSurface(_ id: SurfaceID, capabilities: SurfaceCapabilities,
                                    mode: SurfaceMode = .standard, now: Double) -> CoreOutput {
        if surfaces[id] == nil { order.append(id) }
        surfaces[id] = SurfaceState(capabilities: capabilities, mode: mode)
        return render(id, force: true, now: now)
    }

    /// Removes a surface.
    public mutating func removeSurface(_ id: SurfaceID) {
        surfaces[id] = nil
        order.removeAll { $0 == id }
    }

    /// Changes what a surface's strips show, and returns everything it should show: every strip,
    /// knob position, and switch light, whether changed or not. The Roto-Control holds a knob at
    /// its ends only if the host has sent the knob a position since the last knob-mode change (an
    /// inference from tests 2 and 3; docs/ROTO-CONTROL.md), so its driver calls this after each one.
    public mutating func setMode(_ id: SurfaceID, _ mode: SurfaceMode, now: Double) -> CoreOutput {
        guard surfaces[id] != nil else { return CoreOutput() }
        let next = clamped(mode, for: id)
        surfaces[id]?.mode = next
        return render(id, force: true, now: now)
    }

    /// Resends everything a surface should show (e.g., after its driver reconnects).
    public mutating func resend(_ id: SurfaceID, now: Double) -> CoreOutput {
        render(id, force: true, now: now)
    }

    /// Moves a surface's strips by `pages` pages (a page is the surface's strip count), staying
    /// within the view.
    public mutating func page(_ id: SurfaceID, by pages: Int, now: Double) -> CoreOutput {
        guard let state = surfaces[id] else { return CoreOutput() }
        let step = min(max(pages, -100_000), 100_000) * state.capabilities.stripCount
        let mode: SurfaceMode
        switch state.mode {
        case .strips(let view, let first, let knob, let switchFunction):
            mode = .strips(view: view, first: first + step, knob: knob, switch: switchFunction)
        case .focus(let channel, let first):
            mode = .focus(channel: channel, first: first + step)
        }
        let next = clamped(mode, for: id)
        guard next != state.mode else { return CoreOutput() }
        return setMode(id, next, now: now)
    }

    /// Takes a knob's or fader's new position (0…1) from a surface's strip.
    public mutating func controlMoved(_ id: SurfaceID, strip index: Int, to position: Double, now: Double) -> CoreOutput {
        guard var state = surfaces[id], state.slots.indices.contains(index),
              let target = state.slots[index].binding.knobTarget, position.isFinite else { return CoreOutput() }
        var output = CoreOutput()
        let position = min(max(position, 0), 1)
        let caps = state.capabilities
        let previous = state.physical[index]

        if let guardSize = caps.jumpGuard, let previous, abs(position - previous) > guardSize {
            if caps.feel == .follows, let shown = state.slots[index].knobShown {
                output.add(.knob(index: index, value: shown), for: id)
                state.physical[index] = shown
                surfaces[id] = state
            }
            return output
        }
        if caps.feel == .pickup && !state.caught[index] {
            let current = knobPosition(target) ?? position
            guard Pickup.catches(target: current, previous: previous, position: position, window: caps.pickupWindow) else {
                state.physical[index] = position
                surfaces[id] = state
                return output
            }
            state.caught[index] = true
        }
        state.physical[index] = position
        state.holds[index].lastMove = now
        state.slots[index].wasHeld = true
        state.slots[index].knobShown = position
        surfaces[id] = state

        let value = isPan(target) ? position * 2 - 1 : position
        mirror.set(target, to: value)
        if let message = Self.message(for: target, value: value), let ready = thinner.offer(message, now: now) {
            output.messages.append(ready)
        }
        output.add(.valueText(index: index, text: text(for: target, value: value)), for: id)
        output.append(refresh(where: { $0.contains(target: target) }, now: now))
        return output
    }

    /// Takes a touch or a release of a strip's knob or fader.
    public mutating func touched(_ id: SurfaceID, strip index: Int, _ isTouched: Bool, now: Double) -> CoreOutput {
        guard surfaces[id]?.holds.indices.contains(index) == true else { return CoreOutput() }
        surfaces[id]?.holds[index].touched = isTouched
        if isTouched {
            surfaces[id]?.slots[index].wasHeld = true
            return CoreOutput()
        }
        return tick(now: now)
    }

    /// Takes a press of a strip's switch, which toggles its target.
    public mutating func switchPressed(_ id: SurfaceID, strip index: Int, now: Double) -> CoreOutput {
        guard let state = surfaces[id], state.slots.indices.contains(index),
              let target = state.slots[index].binding.switchTarget else { return CoreOutput() }
        let value: Double = (mirror.value(of: target) ?? 0) >= 0.5 ? 0 : 1
        mirror.set(target, to: value)
        var output = CoreOutput()
        if let message = Self.message(for: target, value: value) { output.messages.append(message) }
        output.append(refresh(where: { $0.contains(target: target) }, now: now))
        return output
    }

    // MARK: - Messages to TotalMix

    /// The message that sets a target to a value: a fader position (0…1), a pan (−1…+1), or 1/0.
    public static func message(for target: ControlTarget, value: Double) -> OSCMessage? {
        let value = Float(value)
        switch target {
        case .level(let ref, let submix):
            if ref.isSource {
                guard let submix else { return nil }
                return TotalMixCommand.setMix(from: ref.bus, ref.channel, to: submix, "faderlin", value)
            }
            return TotalMixCommand.set(ref.bus, ref.channel, "faderlin", value)
        case .pan(let ref, let submix):
            if ref.isSource {
                guard let submix else { return nil }
                return TotalMixCommand.setMix(from: ref.bus, ref.channel, to: submix, "balpan", value)
            }
            return TotalMixCommand.set(ref.bus, ref.channel, "balpan", value)
        case .mute(let ref):
            return TotalMixCommand.set(ref.bus, ref.channel, "mute", value)
        case .pfl(let ref):
            return TotalMixCommand.set(ref.bus, ref.channel, "pfl", value)
        case .solo(let ref, let submix):
            return TotalMixCommand.setMix(from: ref.bus, ref.channel, to: submix, "solo", value)
        }
    }

    // MARK: - Strips

    /// The channel at a position of a view on a surface (as `SurfaceMode.strips` counts from
    /// `first`), or `nil` for a blank strip, a position past the end, or an unknown surface.
    public func channel(at position: Int, of view: ViewKind, on id: SurfaceID) -> ChannelRef? {
        guard let state = surfaces[id] else { return nil }
        let channels = layout.strips(view, in: mirror, pageSize: state.capabilities.stripCount)
        return channels.indices.contains(position) ? channels[position] : nil
    }

    /// What each of a surface's strips is bound to now, or `nil` for an unknown surface.
    public func strips(of id: SurfaceID) -> [StripBinding]? {
        guard let state = surfaces[id] else { return nil }
        return layoutSlots(state).slots
    }

    private func layoutSlots(_ state: SurfaceState) -> (first: Int, count: Int, slots: [StripBinding]) {
        let caps = state.capabilities
        let home = homeSubmix
        var slots: [StripBinding] = []
        switch state.mode {
        case .strips(let view, let first, let knob, let switchFunction):
            let channels = layout.strips(view, in: mirror, pageSize: caps.stripCount)
            for index in 0..<caps.stripCount {
                let position = first + index
                guard position >= 0, position < channels.count, let ref = channels[position] else {
                    slots.append(StripBinding())
                    continue
                }
                let knobTarget = target(for: knob, ref, home: home)
                let switchTarget = caps.hasSwitches ? target(for: switchFunction, ref, home: home) : nil
                slots.append(binding(ref, knob: knobTarget, switch: switchTarget, meter: caps.hasMeters))
            }
            return (first, channels.count, slots)
        case .focus(let ref, let first):
            var knobs: [ControlTarget?] = [target(for: .level, ref, home: home), target(for: .pan, ref, home: home)]
            if ref.isSource { knobs += sendTargets.map { .level(ref, submix: $0) } }
            for index in 0..<caps.stripCount {
                let position = first + index
                let knob = position >= 0 && position < knobs.count ? knobs[position] : nil
                var switchTarget: ControlTarget?
                if caps.hasSwitches {
                    switchTarget = index == 0 ? .mute(ref) : index == 1 ? .pfl(ref) : nil
                }
                if knob == nil && switchTarget == nil {
                    slots.append(StripBinding())
                } else {
                    slots.append(binding(ref, knob: knob, switch: switchTarget, meter: caps.hasMeters && index == 0))
                }
            }
            return (first, knobs.count, slots)
        }
    }

    private func target(for function: KnobFunction, _ ref: ChannelRef, home: Int?) -> ControlTarget? {
        switch function {
        case .level:
            if ref.isSource { return home.map { .level(ref, submix: $0) } }
            return .level(ref, submix: nil)
        case .pan:
            if ref.isSource { return home.map { .pan(ref, submix: $0) } }
            return .pan(ref, submix: nil)
        case .send(let number):
            let sends = sendTargets
            guard ref.isSource, number >= 0, number < sends.count else { return nil }
            return .level(ref, submix: sends[number])
        }
    }

    private func target(for function: SwitchFunction, _ ref: ChannelRef, home: Int?) -> ControlTarget? {
        switch function {
        case .mute: return .mute(ref)
        case .pfl: return .pfl(ref)
        case .solo:
            guard soloEnabled, ref.isSource, let home else { return nil }
            return .solo(ref, submix: home)
        case .none: return nil
        }
    }

    private func binding(_ ref: ChannelRef, knob: ControlTarget?, switch switchTarget: ControlTarget?, meter: Bool) -> StripBinding {
        let state = mirror.channels[ref]
        let kind: StripKind = ref.isSource ? .source
            : mirror.monitoringOutputs.contains(ref.channel) ? .monitoring : .send
        let info = StripInfo(channel: ref, name: Self.stripName(ref, state), color: state?.color,
                             stereo: state?.stereo ?? false, kind: kind, knobLabel: knob.map(label) ?? "",
                             switchLabel: switchTarget.map(label) ?? "")
        var meterChannels: [ChannelRef] = []
        if meter {
            meterChannels = [ref]
            if state?.stereo == true { meterChannels.append(ChannelRef(ref.bus, ref.channel + 1)) }
        }
        return StripBinding(info: info, knobTarget: knob, switchTarget: switchTarget, meterChannels: meterChannels)
    }

    /// The name a strip shows. Playbacks show "PB 1/2" (or "PB 3" for a mono channel), because
    /// TotalMix names each playback after the output of the same number (RME: the default routing
    /// is 1:1), which makes playbacks hard to tell from inputs. Other channels show TotalMix's name.
    public static func stripName(_ ref: ChannelRef, _ state: ChannelState?) -> String {
        if ref.bus == .playback {
            let first = ref.channel + 1
            return state?.stereo == true ? "PB \(first)/\(first + 1)" : "PB \(first)"
        }
        return state?.name ?? ref.description
    }

    private func label(_ target: ControlTarget) -> String {
        switch target {
        case .level(_, let submix?): return outputName(submix)
        case .level: return "Level"
        case .pan: return "Pan"
        case .mute: return "Mute"
        case .pfl: return "PFL"
        case .solo: return "Solo"
        }
    }

    private func outputName(_ output: Int) -> String {
        let ref = ChannelRef(.output, output)
        return mirror.channels[ref]?.name ?? ref.description
    }

    private func isPan(_ target: ControlTarget) -> Bool {
        if case .pan = target { return true }
        return false
    }

    /// A target's value as a knob position (0…1).
    private func knobPosition(_ target: ControlTarget) -> Double? {
        guard let value = mirror.value(of: target) else { return nil }
        return isPan(target) ? (value + 1) / 2 : value
    }

    private func text(for target: ControlTarget, value: Double) -> String {
        isPan(target) ? ValueText.pan(value) : ValueText.level(position: value)
    }

    private func meterValue(_ channels: [ChannelRef]) -> Int? {
        let peaks = channels.compactMap { mirror.meters[$0] }
        guard let peak = peaks.max() else { return nil }
        return MeterScale.value(peakDB: peak)
    }

    private func clamped(_ mode: SurfaceMode, for id: SurfaceID) -> SurfaceMode {
        guard var state = surfaces[id] else { return mode }
        state.mode = mode
        let count = layoutSlots(state).count
        // Past the end, go to the start of the last page, so that pages stay aligned (the
        // Roto-Control pages in multiples of 8).
        let pageSize = max(state.capabilities.stripCount, 1)
        let lastPage = max(count - 1, 0) / pageSize * pageSize
        func fit(_ first: Int) -> Int { first >= count ? lastPage : max(first, 0) }
        switch mode {
        case .strips(let view, let first, let knob, let switchFunction):
            return .strips(view: view, first: fit(first), knob: knob, switch: switchFunction)
        case .focus(let channel, let first):
            return .focus(channel: channel, first: fit(first))
        }
    }

    // MARK: - Rendering

    private mutating func refreshAll(now: Double) -> CoreOutput {
        refresh(where: { _ in true }, now: now)
    }

    /// Renders the surfaces with at least one strip that passes the test.
    private mutating func refresh(where test: (StripBinding) -> Bool, now: Double) -> CoreOutput {
        var output = CoreOutput()
        for id in order {
            guard let state = surfaces[id], state.slots.contains(where: { test($0.binding) }) else { continue }
            output.append(render(id, force: false, now: now))
        }
        return output
    }

    /// Compares what a surface should show with what it was last sent, and sends the difference;
    /// with `force`, sends everything.
    private mutating func render(_ id: SurfaceID, force: Bool, now: Double) -> CoreOutput {
        guard var state = surfaces[id] else { return CoreOutput() }
        var output = CoreOutput()
        let (first, count, bindings) = layoutSlots(state)
        if force || state.page?.first != first || state.page?.count != count {
            state.page = (first, count)
            output.add(.page(first: first, count: count), for: id)
        }
        for (index, binding) in bindings.enumerated() {
            var slot = state.slots[index]
            let old = slot.binding
            slot.binding = binding
            if force || old.info != binding.info {
                output.add(.strip(index: index, info: binding.info), for: id)
            }

            let position = binding.knobTarget.flatMap(knobPosition)
            if force || old.knobTarget != binding.knobTarget {
                state.holds[index] = ControlHold()
                state.caught[index] = false
                slot.wasHeld = false
                slot.knobShown = position
                output.add(.knob(index: index, value: position), for: id)
                if state.capabilities.feel == .follows, let position { state.physical[index] = position }
            } else if Self.differs(position, slot.knobShown) && !state.holds[index].isHeld(now: now) {
                slot.knobShown = position
                state.caught[index] = false
                output.add(.knob(index: index, value: position), for: id)
                if state.capabilities.feel == .follows, let position { state.physical[index] = position }
                if let target = binding.knobTarget, let value = mirror.value(of: target) {
                    output.add(.valueText(index: index, text: text(for: target, value: value)), for: id)
                }
            }

            let on = binding.switchTarget.map { (mirror.value(of: $0) ?? 0) >= 0.5 } ?? false
            if force || old.switchTarget != binding.switchTarget || on != slot.switchShown {
                slot.switchShown = on
                if state.capabilities.hasSwitches {
                    output.add(.switchState(index: index, on: on), for: id)
                }
            }

            if force || old.meterChannels != binding.meterChannels {
                slot.meterPending = nil
                if !binding.meterChannels.isEmpty || force {
                    let value = meterValue(binding.meterChannels) ?? 0
                    slot.meterShown = value
                    slot.meterSentAt = now
                    if state.capabilities.hasMeters {
                        output.add(.meter(index: index, value: value), for: id)
                    }
                }
            }
            state.slots[index] = slot
        }
        surfaces[id] = state
        return output
    }

    /// Whether two knob positions differ by more than rounding (a pan goes through −1…+1 and back).
    private static func differs(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return (a == nil) != (b == nil) }
        return abs(a - b) > 1e-6
    }

    private mutating func meterChanged(_ ref: ChannelRef, now: Double) -> CoreOutput {
        var output = CoreOutput()
        for id in order {
            guard var state = surfaces[id], state.capabilities.hasMeters else { continue }
            for index in state.slots.indices where state.slots[index].binding.meterChannels.contains(ref) {
                guard let value = meterValue(state.slots[index].binding.meterChannels) else { continue }
                var slot = state.slots[index]
                if value == slot.meterShown {
                    slot.meterPending = nil
                } else if now - (slot.meterSentAt ?? -.infinity) >= Self.meterInterval {
                    slot.meterPending = nil
                    slot.meterShown = value
                    slot.meterSentAt = now
                    output.add(.meter(index: index, value: value), for: id)
                } else {
                    slot.meterPending = value
                }
                state.slots[index] = slot
            }
            surfaces[id] = state
        }
        return output
    }
}

/// What one strip is bound to: its channel's description, and the targets of its knob and switch.
public struct StripBinding: Hashable, Sendable {
    /// The strip's channel, name, color, and labels; `nil` for a blank strip.
    public var info: StripInfo?
    /// What the knob or fader controls, if anything.
    public var knobTarget: ControlTarget?
    /// What the switch controls, if anything.
    public var switchTarget: ControlTarget?
    /// The channels whose peak levels the strip's meter shows (both halves of a stereo pair).
    public var meterChannels: [ChannelRef]

    /// A strip's binding; the default is blank.
    public init(info: StripInfo? = nil, knobTarget: ControlTarget? = nil, switchTarget: ControlTarget? = nil,
                meterChannels: [ChannelRef] = []) {
        self.info = info
        self.knobTarget = knobTarget
        self.switchTarget = switchTarget
        self.meterChannels = meterChannels
    }

    func contains(target: ControlTarget) -> Bool {
        knobTarget == target || switchTarget == target
    }

    func contains(node key: NodeKey) -> Bool {
        [knobTarget, switchTarget].contains { target in
            guard let target else { return false }
            switch target {
            case .level(let ref, let submix?), .pan(let ref, let submix?):
                return ref == key.source && submix == key.output
            case .solo(let ref, let submix):
                return ref == key.source && submix == key.output
            default:
                return false
            }
        }
    }
}

/// The hub's record of one surface: its strips as last sent, and the state of its controls.
private struct SurfaceState: Sendable {
    var capabilities: SurfaceCapabilities
    var mode: SurfaceMode
    var page: (first: Int, count: Int)?
    var slots: [Slot]
    var holds: [ControlHold]
    var physical: [Double?]
    var caught: [Bool]

    init(capabilities: SurfaceCapabilities, mode: SurfaceMode) {
        let count = max(capabilities.stripCount, 0)
        self.capabilities = capabilities
        self.mode = mode
        slots = Array(repeating: Slot(), count: count)
        holds = Array(repeating: ControlHold(), count: count)
        physical = Array(repeating: nil, count: count)
        caught = Array(repeating: false, count: count)
    }
}

/// One strip as last sent to its surface.
private struct Slot: Sendable {
    var binding = StripBinding()
    var knobShown: Double?
    var switchShown = false
    var wasHeld = false
    var meterShown: Int?
    var meterPending: Int?
    var meterSentAt: Double?
}
