import XCTest
import OSCCodec
import TotalMixOSC
@testable import SurfaceCore

/// A small TotalMix setup, as `/sendall` would report it:
/// inputs 1/2 (stereo, "Keys"), 3 ("Vox"), 4 ("Gtr"); playbacks 1/2 (stereo, "Tracks");
/// outputs 1/2 (stereo, "Main"), 3/4 (stereo, "Phones"), 5/6 (stereo, hidden from this remote);
/// Main Out on output 1.
private func setupEvents() -> [TotalMixEvent] {
    var events: [TotalMixEvent] = []
    func channel(_ bus: TotalMixBus, _ number: Int, name: String, stereo: Bool, color: Int = 1) {
        events.append(.channel(bus: bus, channel: number, parameter: "stereo", value: .number(stereo ? 1 : 0)))
        events.append(.channel(bus: bus, channel: number, parameter: "name", value: .text(name)))
        events.append(.channel(bus: bus, channel: number, parameter: "color", value: .number(Double(color))))
        events.append(.channel(bus: bus, channel: number, parameter: "mute", value: .number(0)))
        if stereo {
            events.append(.channel(bus: bus, channel: number + 1, parameter: "name", value: .text(name)))
            events.append(.channel(bus: bus, channel: number + 1, parameter: "color", value: .number(Double(color))))
        }
    }
    channel(.input, 0, name: "Keys", stereo: true)
    channel(.input, 2, name: "Vox", stereo: false)
    channel(.input, 3, name: "Gtr", stereo: false)
    channel(.playback, 0, name: "Tracks", stereo: true)
    channel(.output, 0, name: "Main", stereo: true)
    channel(.output, 2, name: "Phones", stereo: true)
    channel(.output, 4, name: "Hidden", stereo: true, color: 0)
    for (bus, number) in [(TotalMixBus.input, 0), (.input, 2), (.input, 3), (.playback, 0)] {
        for output in [0, 2, 4] {
            events.append(.mix(bus: bus, channel: number, output: output, parameter: "faderlin", value: .number(0.5)))
            events.append(.mix(bus: bus, channel: number, output: output, parameter: "balpan", value: .number(0)))
        }
    }
    events.append(.other(path: "controlroom/mainout", value: .number(0)))
    return events
}

private let roto = SurfaceID("roto")
private let rotoCaps = SurfaceCapabilities(stripCount: 8, feel: .follows, hasMeters: true, jumpGuard: 8000.0 / 16383)

private func loadedHub(caps: SurfaceCapabilities = rotoCaps, mode: SurfaceMode = .standard) -> SurfaceHub {
    var hub = SurfaceHub()
    for event in setupEvents() { _ = hub.handle(event, now: 0) }
    _ = hub.addSurface(roto, capabilities: caps, mode: mode, now: 0)
    return hub
}

private func floatArgument(_ message: OSCMessage) -> Float? {
    if case .float(let value)? = message.arguments.first { return value }
    return nil
}

final class MixerMirrorTests: XCTestCase {
    func testChannelsNodesAndMainOut() {
        var mirror = MixerMirror()
        for event in setupEvents() { mirror.apply(event) }
        XCTAssertEqual(mirror.channels[ChannelRef(.input, 2)]?.name, "Vox")
        XCTAssertEqual(mirror.value(of: .level(ChannelRef(.input, 2), submix: 0)), 0.5)
        XCTAssertEqual(mirror.mainOut, 0)
        XCTAssertNil(mirror.apply(.mix(bus: .input, channel: 2, output: 0, parameter: "faderlin", value: .number(0.5))),
                     "an unchanged value is not a change")
    }

    func testDecibelsBecomePositions() {
        var mirror = MixerMirror()
        mirror.apply(.mix(bus: .input, channel: 0, output: 0, parameter: "fader", value: .number(0)))
        mirror.apply(.channel(bus: .output, channel: 0, parameter: "volume", value: .number(-300)))
        XCTAssertEqual(mirror.value(of: .level(ChannelRef(.input, 0), submix: 0)) ?? 0, FaderCurve.unityPosition, accuracy: 1e-9)
        XCTAssertEqual(mirror.value(of: .level(ChannelRef(.output, 0), submix: nil)), 0)
    }

    func testVisibleChannelsSkipRightHalvesAndHidden() {
        var mirror = MixerMirror()
        for event in setupEvents() { mirror.apply(event) }
        XCTAssertEqual(mirror.visibleChannels(.input), [ChannelRef(.input, 0), ChannelRef(.input, 2), ChannelRef(.input, 3)])
        XCTAssertEqual(mirror.visibleChannels(.output), [ChannelRef(.output, 0), ChannelRef(.output, 2)])
        mirror.apply(.channel(bus: .input, channel: 0, parameter: "stereo", value: .number(0)))
        XCTAssertEqual(mirror.visibleChannels(.input).count, 4, "splitting a pair shows both halves")
    }

    func testMainOutNoneIsNil() {
        var mirror = MixerMirror()
        mirror.apply(.other(path: "controlroom/mainout", value: .number(2)))
        mirror.apply(.other(path: "controlroom/mainout", value: .number(-1)))
        XCTAssertNil(mirror.mainOut)
    }
}

final class LayoutTests: XCTestCase {
    func testSourcesAreInputsThenPlaybacks() {
        var mirror = MixerMirror()
        for event in setupEvents() { mirror.apply(event) }
        let sources = PerformanceLayout().channels(.sources, in: mirror)
        XCTAssertEqual(sources, [ChannelRef(.input, 0), ChannelRef(.input, 2), ChannelRef(.input, 3), ChannelRef(.playback, 0)])
    }

    func testChosenOrderThenNewChannels() {
        var mirror = MixerMirror()
        for event in setupEvents() { mirror.apply(event) }
        let layout = PerformanceLayout(sourceOrder: [ChannelRef(.playback, 0), ChannelRef(.input, 2), ChannelRef(.output, 0),
                                                     ChannelRef(.input, 9)])
        XCTAssertEqual(layout.channels(.sources, in: mirror),
                       [ChannelRef(.playback, 0), ChannelRef(.input, 2), ChannelRef(.input, 0), ChannelRef(.input, 3)],
                       "the playback first, then Vox; the rest follow in TotalMix's order; outputs and missing channels are ignored")
        XCTAssertEqual(layout.unplaced(.sources, in: mirror), [ChannelRef(.input, 0), ChannelRef(.input, 3)])
        XCTAssertEqual(PerformanceLayout().unplaced(.sources, in: mirror), [], "with no chosen order nothing is new")
    }

    func testHiddenChannelsStayOut() {
        var mirror = MixerMirror()
        for event in setupEvents() { mirror.apply(event) }
        let layout = PerformanceLayout(sourceOrder: [ChannelRef(.input, 3)], hidden: [ChannelRef(.input, 0), ChannelRef(.output, 2)])
        XCTAssertEqual(layout.channels(.sources, in: mirror), [ChannelRef(.input, 3), ChannelRef(.input, 2), ChannelRef(.playback, 0)])
        XCTAssertEqual(layout.unplaced(.sources, in: mirror), [ChannelRef(.input, 2), ChannelRef(.playback, 0)])
        XCTAssertEqual(layout.channels(.outputs, in: mirror), [ChannelRef(.output, 0)])
    }

    func testOutputOrderKeepsMonitoringFirst() {
        var mirror = MixerMirror()
        for event in setupEvents() { mirror.apply(event) }
        mirror.apply(.channel(bus: .output, channel: 6, parameter: "color", value: .number(1)))
        mirror.apply(.other(path: "controlroom/phones1", value: .number(6)))
        let layout = PerformanceLayout(outputOrder: [ChannelRef(.output, 2), ChannelRef(.output, 6), ChannelRef(.output, 0)])
        XCTAssertEqual(layout.channels(.outputs, in: mirror), [ChannelRef(.output, 6), ChannelRef(.output, 0), ChannelRef(.output, 2)],
                       "monitoring outputs (Phones 1, Main) first in the chosen order, then the send")
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let layout = PerformanceLayout(sourceOrder: [ChannelRef(.input, 3)], hidden: [ChannelRef(.output, 4)])
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(PerformanceLayout.self, from: data), layout)
        XCTAssertEqual(try JSONDecoder().decode(PerformanceLayout.self, from: Data("{}".utf8)), PerformanceLayout(),
                       "missing fields load as empty")
    }
}

final class SurfaceHubTests: XCTestCase {
    func testAddingASurfaceSendsEveryStrip() {
        var hub = SurfaceHub()
        for event in setupEvents() { _ = hub.handle(event, now: 0) }
        let output = hub.addSurface(roto, capabilities: rotoCaps, now: 0)
        let updates = output.updates[roto] ?? []
        XCTAssertTrue(updates.contains(.page(first: 0, count: 4)))
        XCTAssertEqual(updates.filter { if case .strip = $0 { return true }; return false }.count, 8)
        XCTAssertEqual(updates.filter { if case .knob = $0 { return true }; return false }.count, 8)
        XCTAssertTrue(updates.contains(.strip(index: 4, info: nil)), "strips past the last channel are blank")
        guard case .strip(_, let info?)? = updates.first(where: { if case .strip(0, _) = $0 { return true }; return false }) else {
            return XCTFail("no strip 0")
        }
        XCTAssertEqual(info.name, "Keys")
        XCTAssertTrue(info.stereo)
        XCTAssertEqual(info.knobLabel, "Main")
        XCTAssertEqual(info.switchLabel, "Mute")
        XCTAssertTrue(updates.contains(.knob(index: 1, value: 0.5)))
    }

    func testMovingAKnobSetsTheNodeInTheHomeSubmix() {
        var hub = loadedHub()
        let output = hub.controlMoved(roto, strip: 1, to: 0.25, now: 1)
        XCTAssertEqual(output.messages.map(\.address), ["/mix/in/2/0/faderlin"])
        XCTAssertEqual(output.messages.first.flatMap(floatArgument), 0.25)
        XCTAssertEqual(hub.mirror.value(of: .level(ChannelRef(.input, 2), submix: 0)), 0.25)
        XCTAssertTrue(output.updates[roto]?.contains(.valueText(index: 1, text: ValueText.level(position: 0.25))) ?? false)
        XCTAssertFalse(output.updates[roto]?.contains { if case .knob(1, _) = $0 { return true }; return false } ?? true,
                       "the moved knob is not sent its own value")
    }

    func testOtherSurfacesFollowAMove() {
        var hub = loadedHub()
        let other = SurfaceID("other")
        _ = hub.addSurface(other, capabilities: rotoCaps, now: 0)
        let output = hub.controlMoved(roto, strip: 1, to: 0.25, now: 1)
        XCTAssertTrue(output.updates[other]?.contains(.knob(index: 1, value: 0.25)) ?? false)
    }

    func testHeldKnobIgnoresTotalMixUntilLetGo() {
        var hub = loadedHub()
        _ = hub.controlMoved(roto, strip: 1, to: 0.25, now: 1)
        let during = hub.handle(.mix(bus: .input, channel: 2, output: 0, parameter: "faderlin", value: .number(0.7)), now: 1.1)
        XCTAssertNil(during.updates[roto]?.first { if case .knob = $0 { return true }; return false })
        XCTAssertTrue(hub.tick(now: 1.2).updates[roto]?.isEmpty ?? true, "still held 200 ms after the move")
        let after = hub.tick(now: 1.3)
        XCTAssertTrue(after.updates[roto]?.contains(.knob(index: 1, value: 0.7)) ?? false, "caught up once let go")
    }

    func testTouchHoldsUntilReleased() {
        var hub = loadedHub()
        _ = hub.touched(roto, strip: 1, true, now: 1)
        let during = hub.handle(.mix(bus: .input, channel: 2, output: 0, parameter: "faderlin", value: .number(0.7)), now: 2)
        XCTAssertNil(during.updates[roto]?.first { if case .knob = $0 { return true }; return false })
        let released = hub.touched(roto, strip: 1, false, now: 3)
        XCTAssertTrue(released.updates[roto]?.contains(.knob(index: 1, value: 0.7)) ?? false)
    }

    func testNoEchoAfterAMoveSettles() {
        var hub = loadedHub()
        _ = hub.controlMoved(roto, strip: 3, to: 0.75, now: 1)
        XCTAssertTrue(hub.tick(now: 2).updates[roto]?.isEmpty ?? true)
    }

    func testThinnedMessagesKeepTheLatestValue() {
        var hub = loadedHub()
        XCTAssertEqual(hub.controlMoved(roto, strip: 1, to: 0.30, now: 1.000).messages.count, 1)
        XCTAssertEqual(hub.controlMoved(roto, strip: 1, to: 0.31, now: 1.005).messages.count, 0)
        XCTAssertEqual(hub.controlMoved(roto, strip: 1, to: 0.32, now: 1.010).messages.count, 0)
        XCTAssertTrue(hub.tick(now: 1.015).messages.isEmpty)
        let flushed = hub.tick(now: 1.021).messages
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.first.flatMap(floatArgument), 0.32)
    }

    func testPanKnobScalesToBalPan() {
        var hub = loadedHub(mode: .strips(view: .sources, first: 0, knob: .pan, switch: .mute))
        let output = hub.controlMoved(roto, strip: 1, to: 0.75, now: 1)
        XCTAssertEqual(output.messages.map(\.address), ["/mix/in/2/0/balpan"])
        XCTAssertEqual(output.messages.first.flatMap(floatArgument), 0.5)
        XCTAssertTrue(output.updates[roto]?.contains(.valueText(index: 1, text: "R50")) ?? false)
        XCTAssertTrue(hub.tick(now: 2).updates[roto]?.isEmpty ?? true, "no echo from rounding")
    }

    func testSwitchTogglesMute() {
        var hub = loadedHub()
        let on = hub.switchPressed(roto, strip: 2, now: 1)
        XCTAssertEqual(on.messages, [TotalMixCommand.set(.input, 3, "mute", 1)])
        XCTAssertTrue(on.updates[roto]?.contains(.switchState(index: 2, on: true)) ?? false)
        let off = hub.switchPressed(roto, strip: 2, now: 1.01)
        XCTAssertEqual(off.messages, [TotalMixCommand.set(.input, 3, "mute", 0)])
        XCTAssertTrue(off.updates[roto]?.contains(.switchState(index: 2, on: false)) ?? false)
    }

    func testSimultaneousSwitchPressesAllGoOut() {
        var hub = loadedHub()
        var messages: [OSCMessage] = []
        for strip in 0..<4 { messages += hub.switchPressed(roto, strip: strip, now: 1).messages }
        XCTAssertEqual(messages.count, 4, "switches are never thinned")
    }

    func testSendKnobsReachTheOtherVisibleOutputs() {
        var hub = loadedHub(mode: .strips(view: .sources, first: 0, knob: .send(0), switch: .mute))
        XCTAssertEqual(hub.sendTargets, [2])
        XCTAssertEqual(hub.strips(of: roto)?[0].knobTarget, .level(ChannelRef(.input, 0), submix: 2))
        XCTAssertEqual(hub.strips(of: roto)?[0].info?.knobLabel, "Phones")
        _ = hub.setMode(roto, .strips(view: .sources, first: 0, knob: .send(1), switch: .mute), now: 1)
        XCTAssertNil(hub.strips(of: roto)?[0].knobTarget, "there is no second send target")
    }

    func testChoosingTheHomeSubmix() {
        var hub = loadedHub()
        let output = hub.setHomeSubmix(2, now: 1)
        XCTAssertEqual(hub.strips(of: roto)?[1].knobTarget, .level(ChannelRef(.input, 2), submix: 2))
        XCTAssertEqual(hub.sendTargets, [], "Main Out is a monitoring output, so never a send")
        XCTAssertTrue(output.updates[roto]?.contains(.knob(index: 1, value: 0.5)) ?? false)
        _ = hub.setHomeSubmix(nil, now: 2)
        XCTAssertEqual(hub.homeSubmix, 0, "back to following Main Out")
    }

    func testMonitoringOutputsAreNotSends() {
        var hub = loadedHub(mode: .strips(view: .sources, first: 0, knob: .send(0), switch: .mute))
        let events: [TotalMixEvent] = [
            .channel(bus: .output, channel: 6, parameter: "stereo", value: .number(1)),
            .channel(bus: .output, channel: 6, parameter: "name", value: .text("Reverb")),
            .channel(bus: .output, channel: 6, parameter: "color", value: .number(1)),
            .other(path: "controlroom/phones1", value: .number(2)),
        ]
        for event in events { _ = hub.handle(event, now: 1) }
        XCTAssertEqual(hub.mirror.monitoringOutputs, [0, 2])
        XCTAssertEqual(hub.sendTargets, [6], "Main and Phones 1 are monitoring; output 7/8 is a send")
        XCTAssertEqual(hub.strips(of: roto)?[0].knobTarget, .level(ChannelRef(.input, 0), submix: 6))
        _ = hub.setHomeSubmix(2, now: 2)
        XCTAssertEqual(hub.sendTargets, [6], "switching the home submix between monitoring outputs leaves the sends alone")
        _ = hub.handle(.other(path: "controlroom/phones1", value: .number(-1)), now: 3)
        _ = hub.handle(.other(path: "controlroom/cuechan", value: .number(6)), now: 3)
        XCTAssertEqual(hub.sendTargets, [], "output 3/4 is now the home submix and 7/8 the cue output")
    }

    func testOutputsViewPutsMonitoringFirst() {
        var hub = loadedHub(mode: .strips(view: .outputs, first: 0, knob: .level, switch: .mute))
        let events: [TotalMixEvent] = [
            .channel(bus: .output, channel: 6, parameter: "stereo", value: .number(1)),
            .channel(bus: .output, channel: 6, parameter: "name", value: .text("Phones")),
            .channel(bus: .output, channel: 6, parameter: "color", value: .number(1)),
            .other(path: "controlroom/phones1", value: .number(6)),
            .other(path: "controlroom/cuechan", value: .number(4)),
        ]
        for event in events { _ = hub.handle(event, now: 1) }
        let strips = hub.strips(of: roto) ?? []
        XCTAssertEqual(strips.prefix(3).map { $0.info?.channel }, [ChannelRef(.output, 0), ChannelRef(.output, 6), ChannelRef(.output, 2)],
                       "Main, then Phones 1, then the send; the hidden cue output stays hidden")
        XCTAssertEqual(strips.prefix(3).map { $0.info?.kind }, [.monitoring, .monitoring, .send])
        XCTAssertNil(strips[3].info)
        _ = hub.handle(.other(path: "controlroom/phones1", value: .number(-1)), now: 2)
        XCTAssertEqual(hub.strips(of: roto)?.compactMap { $0.info?.channel }, [ChannelRef(.output, 0), ChannelRef(.output, 2), ChannelRef(.output, 6)],
                       "an unassigned role shows no strip; its output becomes a send again")
        XCTAssertEqual(hub.strips(of: roto)?[2].info?.kind, .send)
    }

    func testNoHomeSubmixMeansNoSourceLevels() {
        var hub = SurfaceHub()
        for event in setupEvents() where event != .other(path: "controlroom/mainout", value: .number(0)) {
            _ = hub.handle(event, now: 0)
        }
        _ = hub.addSurface(roto, capabilities: rotoCaps, now: 0)
        XCTAssertNil(hub.strips(of: roto)?[0].knobTarget)
        XCTAssertTrue(hub.controlMoved(roto, strip: 0, to: 0.5, now: 1).messages.isEmpty)
    }

    func testSoloIsOffUntilEnabled() {
        var hub = loadedHub(mode: .strips(view: .sources, first: 0, knob: .level, switch: .solo))
        XCTAssertNil(hub.strips(of: roto)?[0].switchTarget)
        XCTAssertTrue(hub.switchPressed(roto, strip: 0, now: 1).messages.isEmpty)
        _ = hub.setSoloEnabled(true, now: 1)
        XCTAssertEqual(hub.switchPressed(roto, strip: 0, now: 2).messages.map(\.address), ["/mix/in/0/0/solo"])
    }

    func testOutputsViewControlsOutputFaders() {
        var hub = loadedHub(mode: .strips(view: .outputs, first: 0, knob: .level, switch: .mute))
        let output = hub.controlMoved(roto, strip: 1, to: 0.4, now: 1)
        XCTAssertEqual(output.messages.map(\.address), ["/output/2/faderlin"])
        XCTAssertNil(hub.strips(of: roto)?[2].info, "the hidden output is left out")
    }

    func testJumpGuardIgnoresAKnobEndEvent() {
        var hub = loadedHub()
        _ = hub.controlMoved(roto, strip: 1, to: 0.95, now: 1)
        let jump = hub.controlMoved(roto, strip: 1, to: 0.02, now: 1.5)
        XCTAssertTrue(jump.messages.isEmpty)
        XCTAssertEqual(jump.updates[roto], [.knob(index: 1, value: 0.95)], "the knob is put back")
    }

    func testPickupWaitsForTheControlToReachTheValue() {
        let caps = SurfaceCapabilities(stripCount: 8, feel: .pickup, hasSwitches: true)
        var hub = loadedHub(caps: caps)
        XCTAssertTrue(hub.controlMoved(roto, strip: 1, to: 0.10, now: 1).messages.isEmpty)
        XCTAssertTrue(hub.controlMoved(roto, strip: 1, to: 0.30, now: 1.1).messages.isEmpty)
        XCTAssertEqual(hub.controlMoved(roto, strip: 1, to: 0.55, now: 1.2).messages.count, 1, "crossing 0.5 picks it up")
        XCTAssertEqual(hub.controlMoved(roto, strip: 1, to: 0.60, now: 1.3).messages.count, 1)
        _ = hub.handle(.mix(bus: .input, channel: 2, output: 0, parameter: "faderlin", value: .number(0.2)), now: 3)
        XCTAssertTrue(hub.controlMoved(roto, strip: 1, to: 0.65, now: 4).messages.isEmpty, "a change in TotalMix drops the pickup")
    }

    func testPagingStaysInTheView() {
        var hub = SurfaceHub()
        for event in setupEvents() { _ = hub.handle(event, now: 0) }
        let small = SurfaceCapabilities(stripCount: 2, feel: .follows)
        _ = hub.addSurface(roto, capabilities: small, now: 0)
        let next = hub.page(roto, by: 1, now: 1)
        XCTAssertTrue(next.updates[roto]?.contains(.page(first: 2, count: 4)) ?? false)
        XCTAssertEqual(hub.strips(of: roto)?[1].info?.name, "PB 1/2", "playbacks are named by number, not after outputs")
        XCTAssertTrue(hub.page(roto, by: 1, now: 2).isEmpty, "already on the last page")
        XCTAssertEqual(hub.mode(of: roto), .strips(view: .sources, first: 2, knob: .level, switch: .mute))
        _ = hub.page(roto, by: -5, now: 4)
        XCTAssertEqual(hub.mode(of: roto), .standard)
    }

    func testValuesFromTheSurfaceAtTheirExtremes() {
        var hub = loadedHub()
        for strip in [-1, 8, Int.max, Int.min] {
            XCTAssertTrue(hub.controlMoved(roto, strip: strip, to: 0.5, now: 1).isEmpty)
            XCTAssertTrue(hub.switchPressed(roto, strip: strip, now: 1).isEmpty)
            XCTAssertTrue(hub.touched(roto, strip: strip, true, now: 1).isEmpty)
        }
        XCTAssertTrue(hub.controlMoved(roto, strip: 1, to: .nan, now: 1).isEmpty)
        _ = hub.controlMoved(roto, strip: 1, to: 0.1, now: 1.5)
        XCTAssertEqual(hub.controlMoved(roto, strip: 1, to: -3, now: 2).messages.first.flatMap(floatArgument), 0)
        _ = hub.controlMoved(roto, strip: 2, to: 0.9, now: 2.5)
        XCTAssertEqual(hub.controlMoved(roto, strip: 2, to: 7, now: 3).messages.first.flatMap(floatArgument), 1)
        XCTAssertTrue(hub.controlMoved(roto, strip: 3, to: 0, now: 3).messages.isEmpty,
                      "the knob was put at 0.5, so a report of 0 is a jump")
        _ = hub.page(roto, by: Int.max, now: 4)
        _ = hub.page(roto, by: Int.min, now: 5)
        XCTAssertEqual(hub.mode(of: roto), .standard)
        XCTAssertTrue(hub.controlMoved(SurfaceID("unknown"), strip: 0, to: 0.5, now: 6).isEmpty)
    }

    func testModeChangeResendsEveryKnob() {
        var hub = loadedHub()
        let output = hub.setMode(roto, .standard, now: 1)
        XCTAssertEqual(output.updates[roto]?.filter { if case .knob = $0 { return true }; return false }.count, 8)
    }

    func testFocusShowsOneSourceAcrossSubmixes() {
        let hub = loadedHub(mode: .focus(channel: ChannelRef(.input, 2), first: 0))
        let strips = hub.strips(of: roto) ?? []
        let vox = ChannelRef(.input, 2)
        XCTAssertEqual(strips[0].knobTarget, .level(vox, submix: 0))
        XCTAssertEqual(strips[1].knobTarget, .pan(vox, submix: 0))
        XCTAssertEqual(strips[2].knobTarget, .level(vox, submix: 2))
        XCTAssertNil(strips[3].info)
        XCTAssertEqual(strips[0].switchTarget, .mute(vox))
        XCTAssertEqual(strips[1].switchTarget, .pfl(vox))
        XCTAssertEqual(strips[2].info?.knobLabel, "Phones")
    }

    func testMetersAreScaledAndRateLimited() {
        var hub = loadedHub()
        let first = hub.handle(.level(bus: .input, channel: 2, peakDB: -30), now: 1)
        XCTAssertEqual(first.updates[roto], [.meter(index: 1, value: MeterScale.value(peakDB: -30))])
        XCTAssertNil(hub.handle(.level(bus: .input, channel: 2, peakDB: -20), now: 1.02).updates[roto])
        XCTAssertNil(hub.handle(.level(bus: .input, channel: 2, peakDB: -10), now: 1.04).updates[roto])
        XCTAssertEqual(hub.tick(now: 1.09).updates[roto], [.meter(index: 1, value: MeterScale.value(peakDB: -10))])
    }

    func testStereoMeterShowsTheLouderHalf() {
        var hub = loadedHub()
        _ = hub.handle(.level(bus: .input, channel: 0, peakDB: -40), now: 1)
        let right = hub.handle(.level(bus: .input, channel: 1, peakDB: -6), now: 2)
        XCTAssertEqual(right.updates[roto], [.meter(index: 0, value: MeterScale.value(peakDB: -6))])
    }

    func testSendAllIsRepeatedUntilAnswered() {
        var hub = SurfaceHub()
        XCTAssertEqual(hub.connect(now: 0).messages, [TotalMixCommand.sendAll()])
        XCTAssertTrue(hub.tick(now: 0.5).messages.isEmpty)
        XCTAssertEqual(hub.tick(now: 1.0).messages, [TotalMixCommand.sendAll()])
        _ = hub.handle(.other(path: "status/1", value: .number(0)), now: 1.2)
        XCTAssertEqual(hub.tick(now: 2.0).messages, [TotalMixCommand.sendAll()], "a status message is not an answer")
        _ = hub.handle(.channel(bus: .input, channel: 0, parameter: "name", value: .text("Keys")), now: 2.1)
        XCTAssertTrue(hub.tick(now: 5).messages.isEmpty)
    }

    func testNameChangeUpdatesTheStrip() {
        var hub = loadedHub()
        let output = hub.handle(.channel(bus: .input, channel: 2, parameter: "name", value: .text("Lead")), now: 1)
        guard case .strip(1, let info?)? = output.updates[roto]?.first else { return XCTFail("no strip update") }
        XCTAssertEqual(info.name, "Lead")
    }
}

final class StripNameTests: XCTestCase {
    func testPlaybacksAreNamedByNumber() {
        var stereo = ChannelState()
        stereo.stereo = true
        stereo.name = "Main"
        XCTAssertEqual(SurfaceHub.stripName(ChannelRef(.playback, 0), stereo), "PB 1/2")
        XCTAssertEqual(SurfaceHub.stripName(ChannelRef(.playback, 4), ChannelState()), "PB 5")
        XCTAssertEqual(SurfaceHub.stripName(ChannelRef(.input, 0), stereo), "Main", "inputs keep TotalMix's name")
        XCTAssertEqual(SurfaceHub.stripName(ChannelRef(.output, 3), nil), "output 4")
    }
}

final class ScaleAndTextTests: XCTestCase {
    func testMeterScale() {
        XCTAssertEqual(MeterScale.value(peakDB: -90), 0)
        XCTAssertEqual(MeterScale.value(peakDB: -65), 0)
        XCTAssertEqual(MeterScale.value(peakDB: -60), 9)
        XCTAssertEqual(MeterScale.value(peakDB: -32.5), 63)
        XCTAssertEqual(MeterScale.value(peakDB: -0.1), 126)
        XCTAssertEqual(MeterScale.warning, 117, "yellow from -5 dBFS")
        XCTAssertEqual(MeterScale.red, 125, "red from -1 dBFS")
        XCTAssertEqual(MeterScale.value(peakDB: 0), MeterScale.fullScale)
        XCTAssertEqual(MeterScale.value(peakDB: -.infinity), 0)
    }

    func testValueText() {
        XCTAssertEqual(ValueText.level(position: 0), "off")
        XCTAssertEqual(ValueText.level(position: FaderCurve.unityPosition), "0.0 dB")
        XCTAssertEqual(ValueText.level(position: FaderCurve.position(gainDB: -6)), "-6.0 dB")
        XCTAssertEqual(ValueText.level(position: 1), "+6.0 dB")
        XCTAssertEqual(ValueText.pan(0), "C")
        XCTAssertEqual(ValueText.pan(-0.25), "L25")
        XCTAssertEqual(ValueText.pan(1), "R100")
    }

    func testPickupRule() {
        XCTAssertTrue(Pickup.catches(target: 0.5, previous: nil, position: 0.51, window: 0.02))
        XCTAssertFalse(Pickup.catches(target: 0.5, previous: nil, position: 0.6, window: 0.02))
        XCTAssertTrue(Pickup.catches(target: 0.5, previous: 0.4, position: 0.6, window: 0.02))
        XCTAssertFalse(Pickup.catches(target: 0.5, previous: 0.6, position: 0.7, window: 0.02))
    }

    func testPlaybacksOnANewPage() {
        var mirror = MixerMirror()
        for number in 0..<3 {
            _ = mirror.apply(.channel(bus: .input, channel: number, parameter: "name", value: .text("In \(number + 1)")))
        }
        for number in 0..<2 {
            _ = mirror.apply(.channel(bus: .playback, channel: number, parameter: "name", value: .text("PB \(number + 1)")))
        }
        var layout = PerformanceLayout()
        XCTAssertEqual(layout.strips(.sources, in: mirror, pageSize: 2).count, 5, "off: no blanks")
        layout.playbacksOnNewPage = true
        let strips = layout.strips(.sources, in: mirror, pageSize: 2)
        XCTAssertEqual(strips.count, 6)
        XCTAssertNil(strips[3], "one blank fills the inputs' last page")
        XCTAssertEqual(strips[4], ChannelRef(.playback, 0))
        XCTAssertEqual(layout.strips(.sources, in: mirror, pageSize: 3).count, 5, "already on a page boundary")
        XCTAssertEqual(layout.strips(.outputs, in: mirror, pageSize: 2), layout.channels(.outputs, in: mirror).map { $0 })

        let saved = try! JSONEncoder().encode(layout)
        XCTAssertEqual(try! JSONDecoder().decode(PerformanceLayout.self, from: saved), layout)
        let old = try! JSONDecoder().decode(PerformanceLayout.self, from: Data("{\"hidden\":[]}".utf8))
        XCTAssertFalse(old.playbacksOnNewPage)

        var hub = SurfaceHub()
        for event in [TotalMixEvent.channel(bus: .input, channel: 0, parameter: "name", value: .text("In 1")),
                      .channel(bus: .playback, channel: 0, parameter: "name", value: .text("PB 1"))] {
            _ = hub.handle(event, now: 0)
        }
        let id = SurfaceID("test")
        _ = hub.addSurface(id, capabilities: SurfaceCapabilities(stripCount: 4, feel: .follows, hasSwitches: true,
                                                                 hasMeters: false, jumpGuard: nil), now: 0)
        _ = hub.setLayout(PerformanceLayout(playbacksOnNewPage: true), now: 0)
        XCTAssertNil(hub.channel(at: 1, of: .sources, on: id))
        XCTAssertEqual(hub.channel(at: 4, of: .sources, on: id), ChannelRef(.playback, 0))
        XCTAssertEqual(hub.strips(of: id)?.compactMap { $0.info }.count, 1, "first page: the input, then blanks")
    }
}
