import Foundation
#if canImport(CoreMIDI)
import CoreMIDI
#endif

/// A MIDI source or destination, as the system lists it.
public struct MIDIEndpointInfo: Equatable, Sendable {
    /// The name shown to the user (CoreMIDI's display name, which includes the device's name).
    public var name: String
    /// CoreMIDI's unique ID for the endpoint.
    public var uniqueID: Int32

    /// Makes an endpoint description.
    public init(name: String, uniqueID: Int32) {
        self.name = name
        self.uniqueID = uniqueID
    }

    /// The endpoint in `endpoints` whose name is `name`, ignoring case; or else the only one whose
    /// name contains it; or `nil` if none or several do.
    public static func match(_ name: String, in endpoints: [MIDIEndpointInfo]) -> MIDIEndpointInfo? {
        if let exact = endpoints.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let partial = endpoints.filter { $0.name.range(of: name, options: .caseInsensitive) != nil }
        return partial.count == 1 ? partial[0] : nil
    }
}

/// Why a MIDI connection could not be opened or used.
public enum MIDIConnectionError: Error, Equatable, CustomStringConvertible {
    /// A CoreMIDI call failed with this status.
    case coreMIDI(call: String, status: Int32)
    /// No source or destination matched the name, or several did.
    case endpointNotFound(String)
    /// MIDI is not implemented on this platform.
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .coreMIDI(let call, let status): return "\(call) failed with status \(status)."
        case .endpointNotFound(let name): return "No single MIDI port matches \"\(name)\". Run `sbdev roto ports` to list them."
        case .unsupportedPlatform: return "MIDI is only implemented on macOS."
        }
    }
}

#if canImport(CoreMIDI)

/// A two-way MIDI connection to one device through CoreMIDI, using the MIDI 1.0 protocol.
///
/// Received MIDI arrives on CoreMIDI's own thread, as MIDI 1.0 bytes; a SysEx message may arrive
/// in several pieces. `send` may be called from any thread, but not while `close` runs.
public final class MIDIConnection: @unchecked Sendable {
    /// The source being listened to.
    public let source: MIDIEndpointInfo
    /// The destination being sent to.
    public let destination: MIDIEndpointInfo

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private let sourceRef: MIDIEndpointRef
    private let destinationRef: MIDIEndpointRef

    /// The system's MIDI sources (what devices send).
    public static func sources() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfSources()).map { info(MIDIGetSource($0)) }
    }

    /// The system's MIDI destinations (what devices receive).
    public static func destinations() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).map { info(MIDIGetDestination($0)) }
    }

    /// Opens the source and destination that match the given names (see
    /// `MIDIEndpointInfo.match`) and starts delivering received bytes to `receive`.
    public init(clientName: String, sourceName: String, destinationName: String,
                receive: @escaping @Sendable ([UInt8]) -> Void) throws {
        let sources = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
        guard let sourceInfo = MIDIEndpointInfo.match(sourceName, in: sources.map(Self.info)),
              let sourceRef = sources.first(where: { Self.info($0) == sourceInfo }) else {
            throw MIDIConnectionError.endpointNotFound(sourceName)
        }
        guard let destinationInfo = MIDIEndpointInfo.match(destinationName, in: destinations.map(Self.info)),
              let destinationRef = destinations.first(where: { Self.info($0) == destinationInfo }) else {
            throw MIDIConnectionError.endpointNotFound(destinationName)
        }
        source = sourceInfo
        destination = destinationInfo
        self.sourceRef = sourceRef
        self.destinationRef = destinationRef

        try Self.check("MIDIClientCreateWithBlock", MIDIClientCreateWithBlock(clientName as CFString, &client, nil))
        try Self.check("MIDIInputPortCreateWithProtocol",
                       MIDIInputPortCreateWithProtocol(client, "\(clientName) in" as CFString, ._1_0, &inputPort) { list, _ in
            var words: [UInt32] = []
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let offset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12
                let start = UnsafeRawPointer(packet).advanced(by: offset)
                words.append(contentsOf: UnsafeBufferPointer(start: start.assumingMemoryBound(to: UInt32.self), count: count))
            }
            let bytes = UniversalPackets.bytes(fromWords: words)
            if !bytes.isEmpty { receive(bytes) }
        })
        try Self.check("MIDIOutputPortCreate", MIDIOutputPortCreate(client, "\(clientName) out" as CFString, &outputPort))
        try Self.check("MIDIPortConnectSource", MIDIPortConnectSource(inputPort, sourceRef, nil))
    }

    deinit { close() }

    /// Sends complete MIDI 1.0 messages (see `UniversalPackets.words(fromBytes:)`).
    public func send(_ bytes: [UInt8]) throws {
        let words = UniversalPackets.words(fromBytes: bytes)
        guard !words.isEmpty else { return }
        // At most one packet per word, each with a header of 12 bytes or less: a strict bound.
        let size = MemoryLayout<MIDIEventList>.size + words.count * 16
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
        for chunk in UniversalPackets.packets(words) {
            let packetWords = Array(chunk)
            packet = packetWords.withUnsafeBufferPointer { MIDIEventListAdd(list, size, packet!, 0, packetWords.count, $0.baseAddress!) }
            guard packet != nil else { throw MIDIConnectionError.coreMIDI(call: "MIDIEventListAdd", status: -1) }
        }
        try Self.check("MIDISendEventList", MIDISendEventList(outputPort, destinationRef, list))
    }

    /// Whether the source and destination are still in the system's lists and online. When a device
    /// is unplugged, CoreMIDI may mark its endpoints offline or leave them out of the lists (an
    /// inference), so both are checked. Unplugging the Roto-Control has been observed to make this
    /// false (2026-10-31); which of the two checks caught it is not known.
    public var isAvailable: Bool {
        Self.isOnline(sourceRef, among: (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
            && Self.isOnline(destinationRef, among: (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) })
    }

    private static func isOnline(_ endpoint: MIDIEndpointRef, among endpoints: [MIDIEndpointRef]) -> Bool {
        guard endpoints.contains(endpoint) else { return false }
        var offline: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
        return status != noErr || offline == 0
    }

    /// Stops listening and closes the connection.
    public func close() {
        if inputPort != 0 { MIDIPortDisconnectSource(inputPort, sourceRef); MIDIPortDispose(inputPort); inputPort = 0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    private static func info(_ endpoint: MIDIEndpointRef) -> MIDIEndpointInfo {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        var uniqueID: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
        return MIDIEndpointInfo(name: (name?.takeRetainedValue() as String?) ?? "(unnamed)", uniqueID: uniqueID)
    }

    private static func check(_ call: String, _ status: OSStatus) throws {
        guard status == noErr else { throw MIDIConnectionError.coreMIDI(call: call, status: status) }
    }
}

#else

/// A two-way MIDI connection. Only implemented on macOS; elsewhere it lists no ports and throws.
public final class MIDIConnection: @unchecked Sendable {
    /// The source being listened to.
    public let source: MIDIEndpointInfo
    /// The destination being sent to.
    public let destination: MIDIEndpointInfo

    /// No sources on this platform.
    public static func sources() -> [MIDIEndpointInfo] { [] }
    /// No destinations on this platform.
    public static func destinations() -> [MIDIEndpointInfo] { [] }

    /// Throws `MIDIConnectionError.unsupportedPlatform`.
    public init(clientName: String, sourceName: String, destinationName: String,
                receive: @escaping @Sendable ([UInt8]) -> Void) throws {
        throw MIDIConnectionError.unsupportedPlatform
    }

    /// Throws `MIDIConnectionError.unsupportedPlatform`.
    public func send(_ bytes: [UInt8]) throws { throw MIDIConnectionError.unsupportedPlatform }
    /// Always false: there is no connection on this platform.
    public var isAvailable: Bool { false }

    /// Does nothing on this platform.
    public func close() {}
}

#endif
