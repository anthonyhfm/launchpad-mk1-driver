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
    private var statusItem: NSStatusItem?
    private var connectedLaunchpadCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            rootView: ContentView(connectedLaunchpadCount: connectedLaunchpadCount)
                .frame(width: 200, height: 200)
        )
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
