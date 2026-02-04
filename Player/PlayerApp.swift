//
//  PlayerApp.swift
//  Player
//
//  Created by Simon Loffler on 30/10/2025.
//

import SwiftUI
import CoreData

@main
struct PlayerApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            SessionWindowRootView()
                .background(Color.black)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
#else
        WindowGroup {
            SessionWindowRootView()
                .background(Color.black)
        }
#endif
    }
}

#if os(macOS)
struct SessionWindowRootView: View {
    @SceneStorage("xos.window.sessionId") private var persistedSessionId: String = ""
    @State private var generatedSessionId = UUID().uuidString.lowercased()

    private var activeSessionId: String {
        persistedSessionId.isEmpty ? generatedSessionId : persistedSessionId
    }

    var body: some View {
        MediaPlayerRootView(sessionId: activeSessionId)
            .id(activeSessionId)
            .onAppear {
                // Give macOS a runloop turn to restore SceneStorage before creating a new ID.
                DispatchQueue.main.async {
                    if persistedSessionId.isEmpty {
                        persistedSessionId = generatedSessionId
                    }
                }
            }
    }
}
#else
struct SessionWindowRootView: View {
    var body: some View {
        MediaPlayerRootView(sessionId: "default")
    }
}
#endif
