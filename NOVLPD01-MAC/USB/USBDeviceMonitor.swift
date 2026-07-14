import Foundation
import IOKit

@MainActor
protocol USBDeviceMonitoring: AnyObject {
    func currentDevices() -> [USBDevice]
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Observes USB host devices through IOKit. It only discovers devices; it never opens an interface.
@MainActor
final class IOKitUSBDeviceMonitor: USBDeviceMonitoring {
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var launchpadAddedIterator: io_iterator_t = 0
    private var launchpadRemovedIterator: io_iterator_t = 0
    private var onChange: (@MainActor () -> Void)?

    func currentDevices() -> [USBDevice] {
        var devicesByRegistryID: [UInt64: USBDevice] = [:]
        collectDevices(
            matching: usbDeviceMatchingDictionary(),
            label: "all USB devices",
            into: &devicesByRegistryID
        )
        collectDevices(
            matching: launchpadMatchingDictionary(),
            label: "Launchpad Mk1",
            into: &devicesByRegistryID
        )

        let sortedDevices = devicesByRegistryID.values.sorted {
            ($0.locationID, $0.registryEntryID) < ($1.locationID, $1.registryEntryID)
        }

        return sortedDevices
    }

    private func collectDevices(
        matching: CFMutableDictionary,
        label: String,
        into devicesByRegistryID: inout [UInt64: USBDevice]
    ) {
        var iterator: io_iterator_t = 0
        
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        )
        
        guard result == KERN_SUCCESS else { return }
        
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            
            if let device = makeDevice(from: service) {
                devicesByRegistryID[device.registryEntryID] = device
            }
            
            service = IOIteratorNext(iterator)
        }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard notificationPort == nil else { return }

        self.onChange = onChange
        guard let notificationPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.notificationPort = notificationPort
        IONotificationPortSetDispatchQueue(notificationPort, .main)

        registerNotification(
            kIOFirstMatchNotification,
            iterator: &addedIterator,
            notificationPort: notificationPort,
            matching: usbDeviceMatchingDictionary()
        )
        registerNotification(
            kIOTerminatedNotification,
            iterator: &removedIterator,
            notificationPort: notificationPort,
            matching: usbDeviceMatchingDictionary()
        )
        registerNotification(
            kIOFirstMatchNotification,
            iterator: &launchpadAddedIterator,
            notificationPort: notificationPort,
            matching: launchpadMatchingDictionary()
        )
        registerNotification(
            kIOTerminatedNotification,
            iterator: &launchpadRemovedIterator,
            notificationPort: notificationPort,
            matching: launchpadMatchingDictionary()
        )
    }

    func stop() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if launchpadAddedIterator != 0 {
            IOObjectRelease(launchpadAddedIterator)
            launchpadAddedIterator = 0
        }
        if launchpadRemovedIterator != 0 {
            IOObjectRelease(launchpadRemovedIterator)
            launchpadRemovedIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        onChange = nil
    }

    private func registerNotification(
        _ notification: String,
        iterator: inout io_iterator_t,
        notificationPort: IONotificationPortRef,
        matching: CFMutableDictionary
    ) {
        let result = IOServiceAddMatchingNotification(
            notificationPort,
            notification,
            matching,
            { refCon, deviceIterator in
                guard let refCon else { return }
                let monitor = Unmanaged<IOKitUSBDeviceMonitor>.fromOpaque(refCon).takeUnretainedValue()
                monitor.consume(deviceIterator)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )

        guard result == KERN_SUCCESS else { return }

        consume(iterator)
    }

    private func consume(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        
        onChange?()
    }

    /// `IOServiceMatching("IOUSBHostDevice")` omits some USB devices from the
    /// result set. Matching the provider class finds all host-device entries,
    /// including devices that currently have no driver attached.
    private func usbDeviceMatchingDictionary() -> CFMutableDictionary {
        let matching = NSMutableDictionary()
        matching["IOProviderClass"] = "IOUSBHostDevice"
        return matching as CFMutableDictionary
    }

    private func launchpadMatchingDictionary() -> CFMutableDictionary {
        let matching = usbDeviceMatchingDictionary() as NSMutableDictionary
        matching["idVendor"] = NSNumber(value: LaunchpadDevice.vendorID)
        matching["idProduct"] = NSNumber(value: LaunchpadDevice.productID)
        return matching as CFMutableDictionary
    }

    private func makeDevice(from service: io_object_t) -> USBDevice? {
        var registryEntryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS,
              let vendorID = unsignedIntegerProperty("idVendor", from: service),
              let productID = unsignedIntegerProperty("idProduct", from: service),
              let locationID = unsignedIntegerProperty("locationID", from: service) else {
            return nil
        }

        return USBDevice(
            registryEntryID: registryEntryID,
            locationID: UInt32(truncatingIfNeeded: locationID),
            vendorID: UInt16(truncatingIfNeeded: vendorID),
            productID: UInt16(truncatingIfNeeded: productID),
            productName: stringProperty("USB Product Name", from: service)
        )
    }

    private func unsignedIntegerProperty(_ key: String, from service: io_object_t) -> UInt64? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return property.uint64Value
    }

    private func stringProperty(_ key: String, from service: io_object_t) -> String? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String {
        String(format: "0x%0*llX", value.bitWidth / 4, UInt64(value))
    }
}
