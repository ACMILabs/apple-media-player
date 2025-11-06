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
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            MediaPlayerRootView()
                .background(Color.black)
                .onAppear {
#if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
#endif
                }
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
#endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enter fullscreen only after the first runloop turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let w = NSApp.windows.first else { return }
            w.collectionBehavior = [.fullScreenPrimary]
            w.delegate = self
            if !w.styleMask.contains(.fullScreen) {
                w.toggleFullScreen(nil)
            }
        }
    }
}
#endif
