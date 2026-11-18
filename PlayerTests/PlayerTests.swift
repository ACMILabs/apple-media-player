//
//  PlayerTests.swift
//  PlayerTests
//
//  Created by Simon Loffler on 30/10/2025.
//

import Testing
import Foundation
@testable import Player

struct PlayerTests {

    @Test @MainActor func subtitlePositionPersistsAndResetsPerSession() throws {
        let suite = "PlayerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let player = MediaPlayerViewModel(sessionId: "first", defaults: defaults)
        #expect(player.subtitlePosition == MediaPlayerViewModel.defaultSubtitlePosition)
        player.subtitlePosition = CGPoint(x: 0.25, y: 0.4)

        let restored = MediaPlayerViewModel(sessionId: "first", defaults: defaults)
        #expect(restored.subtitlePosition == CGPoint(x: 0.25, y: 0.4))
        let other = MediaPlayerViewModel(sessionId: "second", defaults: defaults)
        #expect(other.subtitlePosition == MediaPlayerViewModel.defaultSubtitlePosition)

        restored.resetSubtitlePosition()
        let reset = MediaPlayerViewModel(sessionId: "first", defaults: defaults)
        #expect(reset.subtitlePosition == MediaPlayerViewModel.defaultSubtitlePosition)
    }

    @Test @MainActor func invalidSubtitlePositionUsesDefault() throws {
        let suite = "PlayerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([2.0, -1.0], forKey: "xos.session.first.subtitles.position")
        let player = MediaPlayerViewModel(sessionId: "first", defaults: defaults)
        #expect(player.subtitlePosition == MediaPlayerViewModel.defaultSubtitlePosition)
    }

}
