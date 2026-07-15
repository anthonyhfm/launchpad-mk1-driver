import Foundation

nonisolated struct MIDIByteStreamTokenizer: Sendable {
    private var runningStatus: UInt8?
    private var pendingStatus: UInt8?
    private var pendingData: [UInt8] = []
    private var expectedDataCount = 0
    private var systemExclusive: [UInt8]?

    mutating func process(_ bytes: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []

        for byte in bytes {
            if byte >= 0xF8 {
                messages.append([byte])
                continue
            }

            if var systemExclusive {
                if byte < 0x80 || byte == 0xF7 {
                    systemExclusive.append(byte)
                    if byte == 0xF7 {
                        messages.append(systemExclusive)
                        self.systemExclusive = nil
                    } else {
                        self.systemExclusive = systemExclusive
                    }
                    continue
                }

                self.systemExclusive = nil
            }

            if byte >= 0x80 {
                begin(status: byte, messages: &messages)
            } else {
                append(dataByte: byte, messages: &messages)
            }
        }

        return messages
    }

    mutating func reset() {
        runningStatus = nil
        pendingStatus = nil
        pendingData.removeAll(keepingCapacity: true)
        expectedDataCount = 0
        systemExclusive = nil
    }

    private mutating func begin(status: UInt8, messages: inout [[UInt8]]) {
        pendingStatus = nil
        pendingData.removeAll(keepingCapacity: true)
        expectedDataCount = 0

        switch status {
        case 0x80...0xEF:
            runningStatus = status
            pendingStatus = status
            expectedDataCount = Self.dataByteCount(for: status)

        case 0xF0:
            runningStatus = nil
            systemExclusive = [status]

        case 0xF1, 0xF3:
            runningStatus = nil
            pendingStatus = status
            expectedDataCount = 1

        case 0xF2:
            runningStatus = nil
            pendingStatus = status
            expectedDataCount = 2

        case 0xF6:
            runningStatus = nil
            messages.append([status])

        case 0xF7:
            runningStatus = nil

        case 0xF4, 0xF5:
            runningStatus = nil

        default:
            runningStatus = nil
        }
    }

    private mutating func append(dataByte: UInt8, messages: inout [[UInt8]]) {
        guard let status = pendingStatus ?? runningStatus else { return }

        if pendingStatus == nil {
            pendingStatus = status
            expectedDataCount = Self.dataByteCount(for: status)
        }

        pendingData.append(dataByte)
        guard pendingData.count == expectedDataCount else { return }

        messages.append([status] + pendingData)
        pendingData.removeAll(keepingCapacity: true)

        if status < 0xF0 {
            pendingStatus = status
        } else {
            pendingStatus = nil
            expectedDataCount = 0
        }
    }

    private static func dataByteCount(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: 1
        default: 2
        }
    }
}
