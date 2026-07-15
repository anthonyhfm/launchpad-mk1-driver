import CoreMIDI
import Foundation

nonisolated final class CoreMIDIClient: @unchecked Sendable {
    let reference: MIDIClientRef

    init(name: String) throws {
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock(name as CFString, &client, nil)
        guard status == noErr else {
            throw CoreMIDIError(operation: "MIDIClientCreate", status: status)
        }
        reference = client
    }

    deinit {
        MIDIClientDispose(reference)
    }
}

nonisolated struct CoreMIDIError: LocalizedError, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with OSStatus \(status)"
    }
}
