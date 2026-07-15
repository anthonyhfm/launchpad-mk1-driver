import Foundation

nonisolated struct MIDIRunningStatusEncoder: Sendable {
    private var runningStatus: UInt8?

    mutating func encode(_ message: [UInt8]) -> [UInt8]? {
        guard let status = message.first, status >= 0x80 else { return nil }

        if status >= 0xF8 {
            return message.count == 1 ? message : nil
        }

        if status < 0xF0 {
            let expectedLength = ((status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0) ? 2 : 3
            guard message.count == expectedLength,
                  message.dropFirst().allSatisfy({ $0 < 0x80 }) else {
                return nil
            }

            if runningStatus == status {
                return Array(message.dropFirst())
            }

            runningStatus = status
            return message
        }

        runningStatus = nil
        return message
    }

    mutating func reset() {
        runningStatus = nil
    }
}
