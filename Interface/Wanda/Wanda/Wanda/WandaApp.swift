//
//  WandaApp.swift
//  Wanda
//
//  Created by Jonathan Jones on 12/6/24.
//

import SwiftUI

@main
struct WandaApp: App {
    // The menu bar icon and the floating glass window live in AppDelegate (WandaPanel.swift).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
