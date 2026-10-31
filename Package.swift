// swift-tools-version:5.9
import PackageDescription
import Foundation

// performance-bridge: Performance Bridge, a macOS app that connects hardware control surfaces to
// RME TotalMix FX through its Global OSC interface, and the Swift libraries behind it.
// Not affiliated with or endorsed by RME, Melbourne Instruments, or Novation.
//
//   OSCCodec       OSC 1.0 messages and bundles, encoded and decoded; Foundation only, builds on
//                  macOS, Linux, and Windows
//   TotalMixOSC    TotalMix FX Global OSC: addresses, the values TotalMix sends and accepts, and the
//                  fader curve; Foundation only
//   RotoControl    Melbourne Instruments Roto-Control: SysEx messages, CCs, 14-bit knobs, and the
//                  handshake; Foundation only
//   MIDITransport  a MIDI connection through CoreMIDI (macOS only; elsewhere it lists no ports and
//                  throws), and the conversion between MIDI 1.0 bytes and CoreMIDI's packets
//   UDPTransport   a small UDP socket for talking to TotalMix (POSIX on macOS and Linux; not yet
//                  implemented on Windows, where it throws)
//   SurfaceCore    the surface-neutral core: TotalMix's state, channel strips, paging, the home
//                  submix, and the rules between surfaces and TotalMix; Foundation only
//   RotoDriver     the Roto-Control's driver: its MIX mode on top of SurfaceCore; Foundation only
//   BridgeEngine   TotalMix and a Roto-Control connected through SurfaceCore and RotoDriver, with
//                  the sockets, the MIDI ports, and a clock: what the app runs
//   sbdev          developer tool for checking the libraries against TotalMix and the surfaces
//
// Planned: the Launch Control XL 3's driver, and the PerformanceBridge app (SwiftUI, macOS only, built
// by make-app.sh).
//
// On a Mac the test targets are opt-in (PERFORMANCE_BRIDGE_TESTS=1), as in 3rd-wave-tools: with only
// the Command Line Tools, SwiftPM fails while looking for XCTest even for a plain `swift build`.

let onMac: Bool = {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}()
let includeTests = !onMac || ProcessInfo.processInfo.environment["PERFORMANCE_BRIDGE_TESTS"] != nil

var targets: [Target] = [
    .target(name: "OSCCodec"),
    .target(name: "TotalMixOSC", dependencies: ["OSCCodec"]),
    .target(name: "RotoControl"),
    .target(name: "MIDITransport"),
    .target(name: "UDPTransport"),
    .target(name: "SurfaceCore", dependencies: ["OSCCodec", "TotalMixOSC"]),
    .target(name: "RotoDriver", dependencies: ["OSCCodec", "TotalMixOSC", "RotoControl", "SurfaceCore"]),
    .target(name: "BridgeEngine", dependencies: ["OSCCodec", "TotalMixOSC", "RotoControl", "MIDITransport", "UDPTransport",
                                                 "SurfaceCore", "RotoDriver"]),
    .executableTarget(name: "sbdev", dependencies: ["OSCCodec", "TotalMixOSC", "RotoControl", "MIDITransport", "UDPTransport",
                                                   "SurfaceCore", "RotoDriver"]),
]
let products: [Product] = [
    .library(name: "OSCCodec", targets: ["OSCCodec"]),
    .library(name: "TotalMixOSC", targets: ["TotalMixOSC"]),
    .library(name: "RotoControl", targets: ["RotoControl"]),
    .library(name: "MIDITransport", targets: ["MIDITransport"]),
    .library(name: "UDPTransport", targets: ["UDPTransport"]),
    .library(name: "SurfaceCore", targets: ["SurfaceCore"]),
    .library(name: "RotoDriver", targets: ["RotoDriver"]),
    .library(name: "BridgeEngine", targets: ["BridgeEngine"]),
    .executable(name: "sbdev", targets: ["sbdev"]),
]

// A first look at the menu-bar app, run with `swift run PerformanceBridge` (macOS only).
if onMac {
    targets.append(.executableTarget(name: "PerformanceBridge", dependencies: ["BridgeEngine", "TotalMixOSC", "SurfaceCore"],
                                     path: "App/PerformanceBridge", resources: [.process("Resources")]))
}

if includeTests {
    targets.append(.testTarget(name: "OSCCodecTests", dependencies: ["OSCCodec"]))
    targets.append(.testTarget(name: "TotalMixOSCTests", dependencies: ["OSCCodec", "TotalMixOSC"]))
    targets.append(.testTarget(name: "RotoControlTests", dependencies: ["RotoControl"]))
    targets.append(.testTarget(name: "MIDITransportTests", dependencies: ["MIDITransport", "RotoControl"]))
    targets.append(.testTarget(name: "UDPTransportTests", dependencies: ["UDPTransport"]))
    targets.append(.testTarget(name: "SurfaceCoreTests", dependencies: ["SurfaceCore", "TotalMixOSC", "OSCCodec"]))
    targets.append(.testTarget(name: "BridgeEngineTests", dependencies: ["BridgeEngine", "SurfaceCore", "TotalMixOSC", "OSCCodec", "UDPTransport"]))
    targets.append(.testTarget(name: "RotoDriverTests", dependencies: ["RotoDriver", "RotoControl", "SurfaceCore", "TotalMixOSC", "OSCCodec"]))
}

let package = Package(
    name: "performance-bridge",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
