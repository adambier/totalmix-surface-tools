// sbdev midi: prints what a MIDI device sends, for finding out what a device such as RME's ARC USB
// sends when its keys are pressed.

import Foundation
import MIDITransport

func midiMonitor(_ arguments: ArraySlice<String>) -> Never {
    guard let name = arguments.first, arguments.count == 1 else {
        fail("Usage: sbdev midi <port name>   (sbdev roto ports lists the ports)")
    }
    let start = Date()
    let connection: MIDIConnection
    do {
        // Reading a source does not stop other programs (e.g., TotalMix) from reading it too.
        connection = try MIDIConnection(clientName: "sbdev midi", sourceName: name, destinationName: name) { bytes in
            print(String(format: "%9.3f  ", Date().timeIntervalSince(start)) + hex(bytes))
            flushOutput()
        }
    } catch {
        fail("\(error)")
    }
    print("Listening to \"\(connection.source.name)\". Press Control-C to stop.")
    flushOutput()
    while true { Thread.sleep(forTimeInterval: 60) }
}
