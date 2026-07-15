import Foundation
import IOKit
import IOUSBHost

nonisolated enum LaunchpadUSBError: LocalizedError, Sendable {
    case deviceNotFound
    case interfaceNotFound
    case openFailed(String)
    case missingPipe(UInt8, String)
    case transferFailed(String, IOReturn)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "Launchpad USB device disappeared before it could be opened"
        case .interfaceNotFound:
            "Launchpad USB interface 0 did not appear after selecting configuration 1"
        case .openFailed(let reason):
            "Could not open Launchpad USB session: \(reason)"
        case .missingPipe(let address, let reason):
            "Could not open USB endpoint \(String(format: "0x%02X", address)): \(reason)"
        case .transferFailed(let direction, let status):
            "USB \(direction) transfer failed with IOReturn \(status)"
        }
    }
}

/// Owns configuration 1, interface 0 and endpoints 0x81/0x02 for one Launchpad.
/// Every method and IO completion is serviced on the session's serial queue.
nonisolated final class LaunchpadUSBTransport: @unchecked Sendable {
    static let configurationValue = 1
    static let interfaceNumber = 0
    static let inputEndpoint: UInt8 = 0x81
    static let outputEndpoint: UInt8 = 0x02

    private let device: USBDevice
    private let queue: DispatchQueue

    private var hostDevice: IOUSBHostDevice?
    private var hostInterface: IOUSBHostInterface?
    private var inputPipe: IOUSBHostPipe?
    private var outputPipe: IOUSBHostPipe?
    private var inputPacketSize = 64
    private var outputPacketSize = 64

    private var pendingWrites: [Data] = []
    private var writeInProgress = false
    private var isActive = false
    private var isStopping = false
    private var didReportDisconnect = false

    private var onInput: (@Sendable ([UInt8]) -> Void)?
    private var onDisconnect: (@Sendable (LaunchpadUSBError) -> Void)?
    private var onReady: (@Sendable (Result<Void, LaunchpadUSBError>) -> Void)?

    init(device: USBDevice, queue: DispatchQueue) {
        self.device = device
        self.queue = queue
    }

    func start(
        onInput: @escaping @Sendable ([UInt8]) -> Void,
        onDisconnect: @escaping @Sendable (LaunchpadUSBError) -> Void,
        completion: @escaping @Sendable (Result<Void, LaunchpadUSBError>) -> Void
    ) {
        self.onInput = onInput
        self.onDisconnect = onDisconnect
        onReady = completion

        if let interfaceService = findInterfaceService() {
            defer { IOObjectRelease(interfaceService) }
            openInterface(interfaceService)
            return
        }

        guard let deviceService = findDeviceService() else {
            finishOpening(.failure(.deviceNotFound))
            return
        }
        defer { IOObjectRelease(deviceService) }

        do {
            let hostDevice = try IOUSBHostDevice(
                __ioService: deviceService,
                options: [],
                queue: queue,
                interestHandler: { [weak self] _, messageType, _ in
                    self?.handleInterest(messageType)
                }
            )
            self.hostDevice = hostDevice
            try hostDevice.__configure(
                withValue: Self.configurationValue,
                matchInterfaces: true
            )
            waitForInterface(attempt: 0)
        } catch {
            finishOpening(.failure(.openFailed(Self.describe(error))))
        }
    }

    func write(_ bytes: [UInt8]) {
        guard isActive, !isStopping, !bytes.isEmpty else { return }

        var offset = 0
        while offset < bytes.count {
            let end = min(offset + outputPacketSize, bytes.count)
            pendingWrites.append(Data(bytes[offset..<end]))
            offset = end
        }
        submitNextWriteIfNeeded()
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        isActive = false
        pendingWrites.removeAll()

        if let inputPipe {
            try? inputPipe.__abort(with: .synchronous)
        }
        if let outputPipe {
            try? outputPipe.__abort(with: .synchronous)
        }

        inputPipe = nil
        outputPipe = nil
        hostInterface?.destroy()
        hostInterface = nil
        hostDevice?.destroy()
        hostDevice = nil

        onInput = nil
        onDisconnect = nil
        onReady = nil
    }

    private func waitForInterface(attempt: Int) {
        guard !isStopping else { return }

        if let interfaceService = findInterfaceService() {
            defer { IOObjectRelease(interfaceService) }
            openInterface(interfaceService)
            return
        }

        guard attempt < 30 else {
            finishOpening(.failure(.interfaceNotFound))
            return
        }

        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.waitForInterface(attempt: attempt + 1)
        }
    }

    private func openInterface(_ service: io_service_t) {
        do {
            let hostInterface = try IOUSBHostInterface(
                __ioService: service,
                options: [],
                queue: queue,
                interestHandler: { [weak self] _, messageType, _ in
                    self?.handleInterest(messageType)
                }
            )
            self.hostInterface = hostInterface

            let inputPipe: IOUSBHostPipe
            do {
                inputPipe = try hostInterface.copyPipe(withAddress: Int(Self.inputEndpoint))
            } catch {
                throw LaunchpadUSBError.missingPipe(Self.inputEndpoint, Self.describe(error))
            }

            let outputPipe: IOUSBHostPipe
            do {
                outputPipe = try hostInterface.copyPipe(withAddress: Int(Self.outputEndpoint))
            } catch {
                throw LaunchpadUSBError.missingPipe(Self.outputEndpoint, Self.describe(error))
            }

            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            inputPacketSize = Self.maxPacketSize(of: inputPipe)
            outputPacketSize = Self.maxPacketSize(of: outputPipe)
            isActive = true

            print("[USB Bridge] Opened Launchpad at \(hex(device.locationID)); IN packet \(inputPacketSize), OUT packet \(outputPacketSize)")
            finishOpening(.success(()))
            submitRead()
        } catch let error as LaunchpadUSBError {
            finishOpening(.failure(error))
        } catch {
            finishOpening(.failure(.openFailed(Self.describe(error))))
        }
    }

    private func submitRead() {
        guard isActive, !isStopping, let inputPipe else { return }

        let transferBuffer = USBTransferBuffer(length: inputPacketSize)
        do {
            try inputPipe.enqueueIORequest(
                with: transferBuffer.data,
                completionTimeout: 0
            ) { [weak self, transferBuffer] status, bytesTransferred in
                guard let self, !self.isStopping else { return }
                guard status == kIOReturnSuccess else {
                    self.reportDisconnect(.transferFailed("IN", status))
                    return
                }

                if bytesTransferred > 0 {
                    let count = min(bytesTransferred, transferBuffer.data.length)
                    let bytes = Array(
                        UnsafeBufferPointer(
                            start: transferBuffer.data.bytes.assumingMemoryBound(to: UInt8.self),
                            count: count
                        )
                    )
                    self.onInput?(bytes)
                }
                self.submitRead()
            }
        } catch {
            reportDisconnect(.openFailed(Self.describe(error)))
        }
    }

    private func submitNextWriteIfNeeded() {
        guard isActive,
              !isStopping,
              !writeInProgress,
              !pendingWrites.isEmpty,
              let outputPipe else { return }

        writeInProgress = true
        let data = pendingWrites.removeFirst()
        let transferBuffer = USBTransferBuffer(data: data)

        do {
            try outputPipe.enqueueIORequest(
                with: transferBuffer.data,
                completionTimeout: 0
            ) { [weak self, transferBuffer] status, bytesTransferred in
                _ = transferBuffer
                guard let self, !self.isStopping else { return }
                self.writeInProgress = false

                guard status == kIOReturnSuccess,
                      bytesTransferred == data.count else {
                    self.reportDisconnect(.transferFailed("OUT", status))
                    return
                }
                self.submitNextWriteIfNeeded()
            }
        } catch {
            writeInProgress = false
            reportDisconnect(.openFailed(Self.describe(error)))
        }
    }

    private func finishOpening(_ result: Result<Void, LaunchpadUSBError>) {
        let completion = onReady
        onReady = nil
        completion?(result)
    }

    private func reportDisconnect(_ error: LaunchpadUSBError) {
        guard !didReportDisconnect, !isStopping else { return }
        didReportDisconnect = true
        isActive = false
        onDisconnect?(error)
    }

    private func handleInterest(_ messageType: UInt32) {
        // kIOMessageServiceIsTerminated is a C macro and is not imported into Swift.
        guard messageType == 0xE000_0010 else { return }
        queue.async { [weak self] in
            self?.reportDisconnect(.deviceNotFound)
        }
    }

    private func findDeviceService() -> io_service_t? {
        firstMatchingService(
            providerClass: "IOUSBHostDevice",
            additionalProperties: [
                "idVendor": NSNumber(value: device.vendorID),
                "idProduct": NSNumber(value: device.productID)
            ],
            matching: { service in
                Self.registryEntryID(of: service) == device.registryEntryID
                    || Self.integerProperty("locationID", of: service) == UInt64(device.locationID)
            }
        )
    }

    private func findInterfaceService() -> io_service_t? {
        firstMatchingService(
            providerClass: "IOUSBHostInterface",
            additionalProperties: [
                "idVendor": NSNumber(value: device.vendorID),
                "idProduct": NSNumber(value: device.productID),
                "bInterfaceNumber": NSNumber(value: Self.interfaceNumber),
                "bConfigurationValue": NSNumber(value: Self.configurationValue)
            ],
            matching: { service in
                Self.integerProperty("locationID", of: service) == UInt64(device.locationID)
            }
        )
    }

    private func firstMatchingService(
        providerClass: String,
        additionalProperties: [String: NSNumber],
        matching predicate: (io_service_t) -> Bool
    ) -> io_service_t? {
        let matching = NSMutableDictionary()
        matching["IOProviderClass"] = providerClass
        additionalProperties.forEach { matching[$0.key] = $0.value }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching as CFMutableDictionary,
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if predicate(service) {
                return service
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private static func registryEntryID(of service: io_service_t) -> UInt64? {
        var value: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &value) == KERN_SUCCESS else {
            return nil
        }
        return value
    }

    private static func integerProperty(_ key: String, of service: io_service_t) -> UInt64? {
        guard let number = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return number.uint64Value
    }

    private static func maxPacketSize(of pipe: IOUSBHostPipe) -> Int {
        let rawValue = pipe.descriptors.pointee.descriptor.wMaxPacketSize
        return max(Int(rawValue & 0x07FF), 1)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) code \(nsError.code), \(nsError.localizedDescription), userInfo: \(nsError.userInfo)"
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String {
        String(format: "0x%0*llX", value.bitWidth / 4, UInt64(value))
    }
}

private nonisolated final class USBTransferBuffer: @unchecked Sendable {
    let data: NSMutableData

    init(length: Int) {
        data = NSMutableData(length: length)!
    }

    init(data: Data) {
        self.data = NSMutableData(data: data)
    }
}
