//
//  NOVLPD01_MACApp.swift
//  NOVLPD01-MAC
//
//  Created by Anthony Hofmeister on 11.07.26.
//

import SwiftUI
import AppKit

@main
struct NOVLPD01_MACApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene { Settings { EmptyView() } }
}

final class MenuBarController: NSObject, NSApplicationDelegate {
    private let popover = NSPopover()
    private let usbRepository = USBRepository()
    private lazy var launchpadRepository = LaunchpadRepository(usbRepository: usbRepository)
    private lazy var connectionStatus = LaunchpadConnectionStatus(repository: launchpadRepository)
    private lazy var sessionManager = LaunchpadSessionManager(repository: launchpadRepository)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = connectionStatus
        _ = sessionManager
        usbRepository.start()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        let icon = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "Launchpad connection")
        icon?.isTemplate = true
        button.image = icon
        button.action = #selector(togglePopover(_:))
        button.target = self
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 200, height: 200)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(connectionStatus: connectionStatus)
                .frame(width: 200, height: 200)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager.stop()
        usbRepository.stop()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
