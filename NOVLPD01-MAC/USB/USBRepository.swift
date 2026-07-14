import Foundation

@MainActor
final class USBRepository {
    private let monitor: any USBDeviceMonitoring
    private var continuations: [UUID: AsyncStream<[USBDevice]>.Continuation] = [:]

    private(set) var devices: [USBDevice] = []

    init() {
        monitor = IOKitUSBDeviceMonitor()
    }

    init(monitor: some USBDeviceMonitoring) {
        self.monitor = monitor
    }

    func start() {
        refreshDevices()
        monitor.start { [weak self] in
            self?.refreshDevices()
        }
    }

    func stop() {
        monitor.stop()
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    func deviceUpdates() -> AsyncStream<[USBDevice]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(devices)
            continuations[id] = continuation
        }
    }

    private func refreshDevices() {
        let updatedDevices = monitor.currentDevices()
        guard updatedDevices != devices else { return }

        devices = updatedDevices
        continuations.values.forEach { $0.yield(updatedDevices) }
    }
}
