import Foundation

/// A USB device identity that remains valid for the duration of its current connection.
nonisolated struct USBDevice: Identifiable, Hashable, Sendable {
    let registryEntryID: UInt64
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16
    let productName: String?

    var id: UInt64 { registryEntryID }
}
