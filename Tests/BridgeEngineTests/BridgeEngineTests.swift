import XCTest
import OSCCodec
import TotalMixOSC
import SurfaceCore
import UDPTransport
@testable import BridgeEngine

final class BridgeEngineTests: XCTestCase {
    func testMonitoringChoicesInOutputOrderWithNamesAndRoles() {
        var mirror = MixerMirror()
        let events: [TotalMixEvent] = [
            .channel(bus: .output, channel: 0, parameter: "name", value: .text("Monitors")),
            .channel(bus: .output, channel: 6, parameter: "name", value: .text("Phones 2")),
            .other(path: "controlroom/mainout", value: .number(0)),
            .other(path: "controlroom/phones1", value: .number(2)),
            .other(path: "controlroom/phones2", value: .number(6)),
            .other(path: "controlroom/mainoutb", value: .number(-1)),
        ]
        for event in events { _ = mirror.apply(event) }
        let choices = BridgeEngine.monitoringChoices(mirror)
        XCTAssertEqual(choices.map(\.output), [0, 2, 6])
        XCTAssertEqual(choices.map(\.name), ["Monitors", "Output 3", "Phones 2"])
        XCTAssertEqual(choices.first?.roles, [.mainOut])
        XCTAssertEqual(choices.last?.roles, [.phones2])
    }

    func testANewEngineIsNotRunning() {
        let engine = BridgeEngine()
        XCTAssertFalse(engine.status.running)
        XCTAssertFalse(engine.status.rotoConnected)
        XCTAssertEqual(engine.settings.endpoint, .standard)
    }

    func testOtherOutputsLeaveOutMonitoringAndHiddenOnes() {
        var mirror = MixerMirror()
        for (number, name) in [(0, "Monitors"), (2, "ADI-2"), (4, "ADAT 1/2"), (6, "ADAT 3/4")] {
            _ = mirror.apply(.channel(bus: .output, channel: number, parameter: "stereo", value: .number(1)))
            _ = mirror.apply(.channel(bus: .output, channel: number, parameter: "name", value: .text(name)))
        }
        _ = mirror.apply(.other(path: "controlroom/mainout", value: .number(0)))
        let layout = PerformanceLayout(hidden: [ChannelRef(.output, 6)])
        let others = BridgeEngine.otherChoices(mirror, layout: layout)
        XCTAssertEqual(others.map(\.name), ["ADI-2", "ADAT 1/2"])
        XCTAssertTrue(others.allSatisfy { $0.roles.isEmpty })
    }

    func testSettingsCarryThePlaybackPageOption() {
        let engine = BridgeEngine(settings: BridgeSettings(playbacksOnNewPage: true))
        XCTAssertTrue(engine.settings.playbacksOnNewPage)
    }

    func testSettingsRetryEveryThreeSecondsByDefault() {
        XCTAssertEqual(BridgeSettings().retryInterval, 3)
    }

    /// TotalMix's port is taken, then freed: the engine runs anyway, says why, and opens the port
    /// on a later try. The Roto-Control is missing throughout (no MIDI here, or no device).
    func testTheEngineKeepsTryingTotalMixsPortAndRunsWithoutTheRotoControl() throws {
        #if os(Windows)
        throw XCTSkip("No UDP sockets on Windows yet")
        #else
        var blocker: UDPSocket? = try UDPSocket(listeningOn: 0, localOnly: true)
        let port = try XCTUnwrap(blocker?.localPort)
        let endpoint = TotalMixEndpoint(host: "127.0.0.1", incomingPort: 9, outgoingPort: port)
        let engine = BridgeEngine(settings: BridgeSettings(endpoint: endpoint, rotoPortName: "No such port here",
                                                           retryInterval: 0.2))
        engine.start()
        defer { engine.stop() }
        XCTAssertTrue(engine.status.running)
        XCTAssertFalse(engine.status.listening)
        XCTAssertFalse(engine.status.rotoFound)
        let error = try XCTUnwrap(engine.status.error)
        XCTAssertTrue(error.contains("Can't listen on port \(port)"), error)
        XCTAssertTrue(error.contains("Roto-Control not found"), error)

        blocker = nil
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, engine.status.error?.contains("Can't listen") == true {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let after = try XCTUnwrap(engine.status.error)
        XCTAssertFalse(after.contains("Can't listen"), after)
        XCTAssertTrue(after.contains("Roto-Control not found"), after)
        XCTAssertTrue(engine.status.listening)
        #endif
    }
}
