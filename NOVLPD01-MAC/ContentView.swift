//
//  ContentView.swift
//  NOVLPD01-MAC
//
//  Created by Anthony Hofmeister on 11.07.26.
//

import SwiftUI

struct ContentView: View {
    let connectionStatus: LaunchpadConnectionStatus

    var body: some View {
        Text("\(connectionStatus.connectedLaunchpadCount) \(connectionStatus.connectedLaunchpadCount == 1 ? "Launchpad" : "Launchpads") Connected")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
