//
//  NOVLPD01_MACApp.swift
//  NOVLPD01-MAC
//
//  Created by Anthony Hofmeister on 11.07.26.
//

import SwiftUI
import AppKit
import ServiceManagement

@main
struct NOVLPD01_MACApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene { Settings { EmptyView() } }
}

final class MenuBarController: NSObject, NSApplicationDelegate {
    private let popover = NSPopover()
    private let usbRepository = USBRepository()
    private let preferences = AppPreferences()
    private lazy var launchpadRepository = LaunchpadRepository(usbRepository: usbRepository)
    private lazy var connectionStatus = LaunchpadConnectionStatus(repository: launchpadRepository)
    private lazy var sessionManager = LaunchpadSessionManager(repository: launchpadRepository)
    private lazy var notificationController = LaunchpadNotificationController(
        repository: launchpadRepository,
        preferences: preferences
    )
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = connectionStatus
        _ = notificationController
        if preferences.isDriverEnabled {
            startDriver()
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        let icon = NSImage(systemSymbolName: "cable.connector.horizontal", accessibilityDescription: "Launchpad USB driver")
        icon?.isTemplate = true
        button.image = icon
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 200, height: 200)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(connectionStatus: connectionStatus)
                .frame(width: 200, height: 50)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager.stop()
        usbRepository.shutdown()
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        togglePopover(sender)
    }

    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }

        popover.performClose(nil)
        let menu = makeContextMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let count = connectionStatus.connectedLaunchpadCount
        let statusItem = NSMenuItem(
            title: preferences.isDriverEnabled
                ? "\(count) \(count == 1 ? "Launchpad" : "Launchpads") Connected"
                : "Driver Disabled",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: preferences.isDriverEnabled ? "Disable Driver" : "Enable Driver",
            action: #selector(toggleDriver)
        ))
        menu.addItem(.separator())

        let loginItem = menuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let notificationsItem = menuItem(
            title: "Device Notifications",
            action: #selector(toggleDeviceNotifications)
        )
        notificationsItem.state = preferences.areDeviceNotificationsEnabled ? .on : .off
        menu.addItem(notificationsItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Close", action: #selector(closeApp)))

        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleDriver() {
        preferences.isDriverEnabled.toggle()

        if preferences.isDriverEnabled {
            startDriver()
        } else {
            stopDriver()
        }
    }

    private func startDriver() {
        usbRepository.start()
        sessionManager.start()
    }

    private func stopDriver() {
        sessionManager.stop()
        usbRepository.stop()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentAlert(
                title: "Could Not Update Login Item",
                message: error.localizedDescription
            )
        }
    }

    @objc private func toggleDeviceNotifications() {
        if preferences.areDeviceNotificationsEnabled {
            notificationController.disableNotifications()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let granted = await notificationController.requestAuthorization()
            guard !granted else { return }

            presentAlert(
                title: "Notifications Are Disabled",
                message: "Allow notifications for NOVLPD01-MAC in System Settings to receive device connection updates."
            )
        }
    }

    @objc private func closeApp() {
        NSApplication.shared.terminate(nil)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
