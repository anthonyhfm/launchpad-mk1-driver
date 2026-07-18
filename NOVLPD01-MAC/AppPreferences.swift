import Foundation

@MainActor
final class AppPreferences {
    private enum Key {
        static let driverEnabled = "driverEnabled"
        static let deviceNotificationsEnabled = "deviceNotificationsEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.driverEnabled: true])
    }

    var isDriverEnabled: Bool {
        get { defaults.bool(forKey: Key.driverEnabled) }
        set { defaults.set(newValue, forKey: Key.driverEnabled) }
    }

    var areDeviceNotificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.deviceNotificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.deviceNotificationsEnabled) }
    }
}
