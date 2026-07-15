import CoreMIDI
import Darwin
import Foundation

nonisolated final class VirtualMIDIPortPair: @unchecked Sendable {
    private(set) var source = MIDIEndpointRef()
    private(set) var destination = MIDIEndpointRef()
    private var isDisposed = false

    init(
        client: CoreMIDIClient,
        sourceName: String,
        destinationName: String,
        onOutput: @escaping @Sendable ([UInt8]) -> Void
    ) throws {
        var source = MIDIEndpointRef()
        var status = MIDISourceCreate(client.reference, sourceName as CFString, &source)
        guard status == noErr else {
            throw CoreMIDIError(operation: "MIDISourceCreate", status: status)
        }

        var destination = MIDIEndpointRef()
        status = MIDIDestinationCreateWithBlock(
            client.reference,
            destinationName as CFString,
            &destination
        ) { packetList, _ in
            onOutput(Self.copyBytes(from: packetList))
        }

        guard status == noErr else {
            MIDIEndpointDispose(source)
            throw CoreMIDIError(operation: "MIDIDestinationCreate", status: status)
        }

        self.source = source
        self.destination = destination
    }

    func publish(_ messages: [[UInt8]]) {
        guard !isDisposed, !messages.isEmpty else { return }

        let byteCount = messages.reduce(0) { $0 + $1.count }
        let capacity = MemoryLayout<MIDIPacketList>.size
            + byteCount
            + messages.count * MemoryLayout<MIDIPacket>.size
            + 64
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { storage.deallocate() }

        let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIPacket>? = MIDIPacketListInit(packetList)
        let timestamp = mach_absolute_time()

        for message in messages {
            for chunk in message.chunked(maxLength: Int(UInt16.max)) {
                guard let currentPacket = packet else { return }
                let addedPacket: UnsafeMutablePointer<MIDIPacket>? = chunk.withUnsafeBytes { rawBuffer in
                    let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                    return MIDIPacketListAdd(
                        packetList,
                        capacity,
                        currentPacket,
                        timestamp,
                        rawBuffer.count,
                        baseAddress
                    )
                }
                guard let addedPacket else {
                    print("[MIDI] Could not append packet to MIDIPacketList")
                    return
                }
                packet = addedPacket
            }
        }

        let status = MIDIReceived(source, packetList)
        if status != noErr {
            print("[MIDI] MIDIReceived failed with OSStatus \(status)")
        }
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true

        if destination != 0 {
            MIDIEndpointDispose(destination)
            destination = 0
        }
        if source != 0 {
            MIDIEndpointDispose(source)
            source = 0
        }
    }

    deinit {
        dispose()
    }

    private static func copyBytes(from packetList: UnsafePointer<MIDIPacketList>) -> [UInt8] {
        var bytes: [UInt8] = []
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        var packetPointer = UnsafeRawPointer(packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)

        for _ in 0..<packetList.pointee.numPackets {
            let packet = packetPointer.pointee
            withUnsafeBytes(of: packet.data) { packetData in
                bytes.append(contentsOf: packetData.prefix(Int(packet.length)))
            }
            packetPointer = UnsafePointer(MIDIPacketNext(packetPointer))
        }

        return bytes
    }
}

private nonisolated extension Array where Element == UInt8 {
    func chunked(maxLength: Int) -> [[UInt8]] {
        guard count > maxLength else { return [self] }

        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maxLength, count)
            chunks.append(Array(self[offset..<end]))
            offset = end
        }
        return chunks
    }
}
