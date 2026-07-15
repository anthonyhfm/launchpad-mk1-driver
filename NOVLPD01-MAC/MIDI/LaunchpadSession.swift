import Foundation

nonisolated enum LaunchpadSessionState: String, Sendable {
    case detected
    case opening
    case active
    case disconnecting
    case stopped
    case failed
}

/// One independent USB ↔ MIDI bridge for one physical Launchpad Mk1.
nonisolated final class LaunchpadSession: @unchecked Sendable {
    let device: LaunchpadDevice
    let number: Int

    private let midiClient: CoreMIDIClient
    private let queue: DispatchQueue
    private var state: LaunchpadSessionState = .detected
    private var transport: LaunchpadUSBTransport?
    private var midiPorts: VirtualMIDIPortPair?
    private var inputTokenizer = MIDIByteStreamTokenizer()
    private var outputTokenizer = MIDIByteStreamTokenizer()
    private var outputEncoder = MIDIRunningStatusEncoder()

    init(device: LaunchpadDevice, number: Int, midiClient: CoreMIDIClient) {
        self.device = device
        self.number = number
        self.midiClient = midiClient
        queue = DispatchQueue(
            label: "dev.anthonyhfm.NOVLPD01-MAC.launchpad.\(device.id)",
            qos: .userInitiated
        )
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stopSynchronously() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard state == .detected || state == .stopped else { return }
        transition(to: .opening)

        let transport = LaunchpadUSBTransport(
            device: device.usbDevice,
            queue: queue
        )
        self.transport = transport

        transport.start(
            onInput: { [weak self] bytes in
                self?.receiveUSB(bytes)
            },
            onDisconnect: { [weak self] error in
                self?.fail(error)
            },
            completion: { [weak self] result in
                self?.finishOpening(result)
            }
        )
    }

    private func finishOpening(_ result: Result<Void, LaunchpadUSBError>) {
        guard state == .opening else { return }

        switch result {
        case .success:
            do {
                let portName = number == 1
                    ? "Launchpad Mk1"
                    : "Launchpad Mk1 #\(number)"
                let ports = try VirtualMIDIPortPair(
                    client: midiClient,
                    sourceName: portName,
                    destinationName: portName,
                    onOutput: { [weak self] bytes in
                        guard let self else { return }
                        self.queue.async {
                            self.receiveMIDI(bytes)
                        }
                    }
                )
                midiPorts = ports
                transition(to: .active)
                print("[Launchpad #\(number)] Bridge active at location \(hex(device.locationID))")
            } catch {
                fail(error)
            }

        case .failure(let error):
            fail(error)
        }
    }

    private func receiveUSB(_ bytes: [UInt8]) {
        guard state == .active else { return }
        let messages = inputTokenizer.process(bytes)
        midiPorts?.publish(messages)
    }

    private func receiveMIDI(_ bytes: [UInt8]) {
        guard state == .active else { return }

        let messages = outputTokenizer.process(bytes)
        var encodedBytes: [UInt8] = []
        for message in messages {
            if let encoded = outputEncoder.encode(message) {
                encodedBytes.append(contentsOf: encoded)
            }
        }
        transport?.write(encodedBytes)
    }

    private func fail(_ error: Error) {
        guard state != .failed,
              state != .disconnecting,
              state != .stopped else { return }

        print("[Launchpad #\(number)] Session failed: \(error.localizedDescription)")
        midiPorts?.dispose()
        midiPorts = nil
        transport?.stop()
        transport = nil
        inputTokenizer.reset()
        outputTokenizer.reset()
        outputEncoder.reset()
        transition(to: .failed)
    }

    private func stopOnQueue() {
        guard state != .stopped else { return }
        transition(to: .disconnecting)

        midiPorts?.dispose()
        midiPorts = nil
        transport?.stop()
        transport = nil
        inputTokenizer.reset()
        outputTokenizer.reset()
        outputEncoder.reset()

        transition(to: .stopped)
        print("[Launchpad #\(number)] Session stopped")
    }

    private func transition(to newState: LaunchpadSessionState) {
        state = newState
        print("[Launchpad #\(number)] State: \(newState.rawValue)")
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String {
        String(format: "0x%0*llX", value.bitWidth / 4, UInt64(value))
    }
}
