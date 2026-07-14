//
//  ContentView.swift
//  NOVLPD01-MAC
//
//  Created by Anthony Hofmeister on 11.07.26.
//

import SwiftUI

struct ContentView: View {
    let connectedLaunchpadCount: Int

    var body: some View {
        Text("\(connectedLaunchpadCount) Launchpads Connected")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(connectedLaunchpadCount: 0)
        .frame(width: 200, height: 200)
}
