import Foundation

nonisolated struct LaunchpadDevice: Identifiable, Hashable, Sendable {
    static let vendorID: UInt16 = 0x1235
    static let productID: UInt16 = 0x000e

    let usbDevice: USBDevice

    var id: UInt64 { usbDevice.id }
    var locationID: UInt32 { usbDevice.locationID }
}

@MainActor
final class LaunchpadRepository {
    private let usbRepository: USBRepository
    private var observationTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[LaunchpadDevice]>.Continuation] = [:]

    private(set) var launchpads: [LaunchpadDevice] = []

    init(usbRepository: USBRepository) {
        self.usbRepository = usbRepository
        observationTask = Task { [weak self, usbRepository] in
            for await devices in usbRepository.deviceUpdates() {
                guard let self else { return }
                self.updateLaunchpads(from: devices)
            }
        }
    }

    func launchpadUpdates() -> AsyncStream<[LaunchpadDevice]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(launchpads)
            continuations[id] = continuation
        }
    }

    private func updateLaunchpads(from devices: [USBDevice]) {
        let updatedLaunchpads = devices
            .filter { $0.vendorID == LaunchpadDevice.vendorID && $0.productID == LaunchpadDevice.productID }
            .map(LaunchpadDevice.init)

        guard updatedLaunchpads != launchpads else { return }
        
        launchpads = updatedLaunchpads
        
        continuations.values.forEach { $0.yield(updatedLaunchpads) }
    }
}
