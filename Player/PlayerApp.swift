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
#if os(macOS)
        WindowGroup(id: SessionWindowRootView.windowGroupID) {
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
@MainActor
final class SessionRestoreCoordinator {
    static let shared = SessionRestoreCoordinator()

    private let defaults = UserDefaults.standard
    private let savedSessionsKey = "xos.app.savedSessionIds"

    private var hasPreparedLaunchState = false
    private var hasScheduledWindowRestore = false
    private(set) var isTerminating = false
    private var initialSavedSessionCount = 0
    private var expectedSessionIdsForLaunch: [String] = []
    private var activeSessionIds: [String] = []

    private init() {}

    func prepareLaunchStateIfNeeded() {
        guard !hasPreparedLaunchState else { return }
        expectedSessionIdsForLaunch = defaults.stringArray(forKey: savedSessionsKey) ?? []
        initialSavedSessionCount = max(1, expectedSessionIdsForLaunch.count)
        hasPreparedLaunchState = true
    }

    func claimSessionId(fallback: String) -> String {
        prepareLaunchStateIfNeeded()
        guard !expectedSessionIdsForLaunch.isEmpty else { return fallback }
        return expectedSessionIdsForLaunch.removeFirst()
    }

    func markSessionAsRestored(_ sessionId: String) {
        prepareLaunchStateIfNeeded()
        if let idx = expectedSessionIdsForLaunch.firstIndex(of: sessionId) {
            expectedSessionIdsForLaunch.remove(at: idx)
        }
    }

    func registerActiveSession(_ sessionId: String) {
        guard !activeSessionIds.contains(sessionId) else { return }
        activeSessionIds.append(sessionId)
        persistActiveSessions()
    }

    func unregisterActiveSession(_ sessionId: String) {
        guard !isTerminating else { return }
        activeSessionIds.removeAll { $0 == sessionId }
        persistActiveSessions()
    }

    func markApplicationTerminating() {
        isTerminating = true
    }

    func restoreAdditionalWindowsIfNeeded(openWindow: OpenWindowAction) {
        prepareLaunchStateIfNeeded()
        guard !hasScheduledWindowRestore else { return }
        hasScheduledWindowRestore = true

        let targetCount = initialSavedSessionCount
        guard targetCount > 1 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let missingWindowCount = max(0, targetCount - self.activeSessionIds.count)
            guard missingWindowCount > 0 else { return }
            for _ in 0..<missingWindowCount {
                openWindow(id: SessionWindowRootView.windowGroupID)
            }
        }
    }

    private func persistActiveSessions() {
        defaults.set(activeSessionIds, forKey: savedSessionsKey)
    }
}

struct SessionWindowRootView: View {
    static let windowGroupID = "xos.player.windowgroup"

    @SceneStorage("xos.window.sessionId") private var persistedSessionId: String = ""
    @State private var generatedSessionId = UUID().uuidString.lowercased()
    @Environment(\.openWindow) private var openWindow

    private var activeSessionId: String {
        persistedSessionId.isEmpty ? generatedSessionId : persistedSessionId
    }

    var body: some View {
        MediaPlayerRootView(sessionId: activeSessionId)
            .id(activeSessionId)
            .onAppear {
                DispatchQueue.main.async {
                    if persistedSessionId.isEmpty {
                        persistedSessionId = SessionRestoreCoordinator.shared.claimSessionId(fallback: generatedSessionId)
                    } else {
                        SessionRestoreCoordinator.shared.markSessionAsRestored(persistedSessionId)
                    }

                    SessionRestoreCoordinator.shared.registerActiveSession(persistedSessionId)
                    SessionRestoreCoordinator.shared.restoreAdditionalWindowsIfNeeded(openWindow: openWindow)
                }
            }
            .onDisappear {
                guard !persistedSessionId.isEmpty else { return }
                SessionRestoreCoordinator.shared.unregisterActiveSession(persistedSessionId)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionRestoreCoordinator.shared.markApplicationTerminating()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionRestoreCoordinator.shared.markApplicationTerminating()
    }
}
#else
struct SessionWindowRootView: View {
    var body: some View {
        MediaPlayerRootView(sessionId: "default")
    }
}
#endif
