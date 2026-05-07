//
//  dhoop_uiApp.swift
//  dhoop-ui
//
//  Created by Joshua Cooper on 5/7/26.
//

import SwiftUI

@main
struct dhoop_uiApp: App {
    @StateObject private var bleManager = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
        }
    }
}
