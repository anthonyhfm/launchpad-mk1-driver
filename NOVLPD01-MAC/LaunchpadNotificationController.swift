import Foundation
import UserNotifications

@MainActor
final class LaunchpadNotificationController {
    private let repository: LaunchpadRepository
    private let preferences: AppPreferences
    private let notificationCenter: UNUserNotificationCenter
    private var observationTask: Task<Void, Never>?

    init(
        repository: LaunchpadRepository,
        preferences: AppPreferences,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.repository = repository
        self.preferences = preferences
        self.notificationCenter = notificationCenter

        observationTask = Task { [weak self, repository] in
            var previousLaunchpads: [UInt64: LaunchpadDevice]?

            for await launchpads in repository.launchpadUpdates() {
                guard let self else { return }
                let currentLaunchpads = Dictionary(
                    uniqueKeysWithValues: launchpads.map { ($0.id, $0) }
                )

                if let previousLaunchpads, self.preferences.areDeviceNotificationsEnabled {
                    for launchpad in currentLaunchpads.values where previousLaunchpads[launchpad.id] == nil {
                        self.sendNotification(
                            title: "Launchpad connected",
                            body: self.deviceName(for: launchpad) + " is ready to use."
                        )
                    }

                    for launchpad in previousLaunchpads.values where currentLaunchpads[launchpad.id] == nil {
                        self.sendNotification(
                            title: "Launchpad disconnected",
                            body: self.deviceName(for: launchpad) + " was removed."
                        )
                    }
                }

                previousLaunchpads = currentLaunchpads
            }
        }
    }

    func requestAuthorization() async -> Bool {
        let settings = await notificationCenter.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            preferences.areDeviceNotificationsEnabled = true
            return true

        case .notDetermined:
            do {
                let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                preferences.areDeviceNotificationsEnabled = granted
                return granted
            } catch {
                preferences.areDeviceNotificationsEnabled = false
                return false
            }

        case .denied:
            preferences.areDeviceNotificationsEnabled = false
            return false

        @unknown default:
            preferences.areDeviceNotificationsEnabled = false
            return false
        }
    }

    func disableNotifications() {
        preferences.areDeviceNotificationsEnabled = false
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func deviceName(for launchpad: LaunchpadDevice) -> String {
        launchpad.usbDevice.productName ?? "Launchpad Mk1"
    }
}
