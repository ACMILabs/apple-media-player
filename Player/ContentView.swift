//
//  ContentView.swift
//  Player
//
//  Created by Simon Loffler on 30/10/2025.
//

// SwiftUI XOS Media Player
// macOS + tvOS single-file app with simple, readable code
// - Fullscreen looping playback of a playlist
// - Tap/click anywhere to open a settings sheet to change playlist ID and clear cache
// - Caches playlist JSON and video files; prefers cached media
// - Shows a loading image while preparing, and a no‑internet image if nothing cached

import SwiftUI
import AVKit
import Combine

// MARK: - Models

struct XOSPlaylistResponse: Codable {
    struct PlaylistLabel: Codable {
        struct Label: Codable { let id: Int? }
        let label: Label?
        let resource: String?
        let subtitles: String?
    }
    let playlist_labels: [PlaylistLabel]
}

struct CachedPlaylist: Codable {
    let fetchedAt: Date
    let playlist: XOSPlaylistResponse
}

// MARK: - Platform Helpers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - View Model

@MainActor
final class MediaPlayerViewModel: ObservableObject {
    let sessionId: String
    private let defaults: UserDefaults
    private var isHydratingFromDefaults = true

    // MARK: Public UI State
    @Published var isShowingSettingsSheet: Bool = false
    @Published var isLoadingPlaylistAndVideos: Bool = true
    @Published var isOfflineWithNoCachedData: Bool = false
    @Published var userEditablePlaylistIdentifier: String = "1" {
        didSet { persist(userEditablePlaylistIdentifier, for: .playlistIdentifier) }
    }
    @Published var userEditableXOSApiEndpointBase: String = MediaPlayerViewModel.defaultXOSApiEndpointBase {
        didSet { persist(userEditableXOSApiEndpointBase, for: .xosApiEndpointBase) }
    }
    @Published var avQueuePlayer: AVQueuePlayer = AVQueuePlayer()
    @Published var isPlaybackMuted: Bool = false {
        didSet {
            avQueuePlayer.isMuted = isPlaybackMuted
            persist(isPlaybackMuted, for: .playbackMuted)
        }
    }
    @Published var videoControlsEnabled: Bool = false {
        didSet { persist(videoControlsEnabled, for: .videoControlsEnabled) }
    }

    // MARK: Subtitles + Sync Settings (moved from extension)
    @Published var showSubtitlesIfAvailable: Bool = false {
        didSet { persist(showSubtitlesIfAvailable, for: .subtitlesEnabled) }
    }
    @Published var subtitleFontPointSize: CGFloat = 28 {
        didSet { persist(Int(subtitleFontPointSize), for: .subtitleFontSize) }
    }
    @Published var subtitleIsBold: Bool = false {
        didSet { persist(subtitleIsBold, for: .subtitleBold) }
    }

    @Published var isThisDeviceTheSyncServer: Bool = false {
        didSet {
            persist(isThisDeviceTheSyncServer, for: .syncIsServer)
            setupSyncNetworkingIfConfigured()
        }
    }
    @Published var syncServerHostnameOrIpAddress: String = "" {
        didSet {
            persist(syncServerHostnameOrIpAddress, for: .syncServerHost)
            setupSyncNetworkingIfConfigured()
        }
    }
    @Published var syncListeningPortNumber: UInt16 = 10000 {
        didSet {
            persist(Int(syncListeningPortNumber), for: .syncPort)
            setupSyncNetworkingIfConfigured()
        }
    }
    @Published var syncDriftThresholdMilliseconds: Int = 20 {
        didSet { persist(syncDriftThresholdMilliseconds, for: .syncDriftThresholdMs) }
    }
    @Published var syncLatencyMilliseconds: Int = 167 {
        didSet { persist(syncLatencyMilliseconds, for: .syncLatencyMs) }
    }
    @Published var syncIgnoreThresholdMilliseconds: Int = 2000 {
        didSet { persist(syncIgnoreThresholdMilliseconds, for: .syncIgnoreThresholdMs) }
    }

    @Published var currentlyVisibleSubtitleText: String = ""

    // MQTT message server for label syncing
    @Published var brokerIsEnabled: Bool = false {
        didSet {
            persist(brokerIsEnabled, for: .brokerEnabled)
            setupBrokerIfConfigured()
        }
    }
    @Published var brokerURLString: String = "" {
        didSet {
            persist(brokerURLString, for: .brokerURL)
            setupBrokerIfConfigured()
        }
    }
    @Published var brokerClientId: String = "" {
        didSet {
            persist(brokerClientId, for: .brokerClientId)
            setupBrokerIfConfigured()
        }
    }
    @Published var mediaPlayerIdentifierForBroker: String = "1" {
        didSet {
            persist(mediaPlayerIdentifierForBroker, for: .mediaPlayerId)
            setupBrokerIfConfigured()
        }
    }
    @Published var brokerPostIntervalSeconds: Double = 0.5 {
        didSet { persist(brokerPostIntervalSeconds, for: .brokerIntervalSeconds) }
    }

    private var brokerPublisher: MQTTBrokerPublisher?
    private var brokerTicker: Timer?
    private var lastPostedIndex: Int = -1

    // Subtitle parsing cache
    private var subtitleCuesByLocalVideoURL: [URL: [SubtitleCue]] = [:]

    // Sync internals
    private var syncServer: SimpleSyncServer?
    private var syncClient: SimpleSyncClient?
    private var serverTicker: Timer?
    private var playerTimeObserverToken: Any?
    private var syncLockedIndex: Int? = nil

    // MARK: Configuration
    private static let defaultXOSApiEndpointBase: String = "https://xos.acmi.net.au/api/"
    private var xosApiEndpointBase: String {
        let trimmed = userEditableXOSApiEndpointBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultXOSApiEndpointBase : trimmed
    }
    private var xosPlaylistEndpoint: String { xosApiEndpointBase.hasSuffix("/") ? xosApiEndpointBase + "playlists/" : xosApiEndpointBase + "/playlists/" }
    private var lastLoadedPlaylist: XOSPlaylistResponse? = nil

    // MARK: Initialisation
    init(sessionId: String, defaults: UserDefaults = .standard) {
        self.sessionId = sessionId
        self.defaults = defaults
        hydrateStateFromDefaults()
        isHydratingFromDefaults = false
    }

    private enum SessionSetting: String {
        case playlistIdentifier = "playlist.id"
        case xosApiEndpointBase = "xos.apiEndpointBase"
        case playbackMuted = "playback.muted"
        case videoControlsEnabled = "video.controlsEnabled"
        case subtitlesEnabled = "subtitles.show"
        case subtitleFontSize = "subtitles.fontSize"
        case subtitleBold = "subtitles.bold"
        case syncIsServer = "sync.isServer"
        case syncServerHost = "sync.serverHost"
        case syncPort = "sync.port"
        case syncDriftThresholdMs = "sync.driftThresholdMs"
        case syncLatencyMs = "sync.latencyMs"
        case syncIgnoreThresholdMs = "sync.ignoreThresholdMs"
        case brokerEnabled = "broker.enabled"
        case brokerURL = "broker.url"
        case brokerClientId = "broker.clientId"
        case mediaPlayerId = "mediaplayer.id"
        case brokerIntervalSeconds = "broker.interval"
    }

    private func namespacedKey(_ setting: SessionSetting) -> String {
        "xos.session.\(sessionId).\(setting.rawValue)"
    }

    private func persist(_ value: Any, for setting: SessionSetting) {
        guard !isHydratingFromDefaults else { return }
        defaults.set(value, forKey: namespacedKey(setting))
    }

    private func hydrateStateFromDefaults() {
        userEditablePlaylistIdentifier = defaults.string(forKey: namespacedKey(.playlistIdentifier)) ?? "1"
        userEditableXOSApiEndpointBase = defaults.string(forKey: namespacedKey(.xosApiEndpointBase)) ?? Self.defaultXOSApiEndpointBase
        isPlaybackMuted = defaults.object(forKey: namespacedKey(.playbackMuted)) as? Bool ?? false
        videoControlsEnabled = defaults.object(forKey: namespacedKey(.videoControlsEnabled)) as? Bool ?? false
        showSubtitlesIfAvailable = defaults.object(forKey: namespacedKey(.subtitlesEnabled)) as? Bool ?? false
        subtitleFontPointSize = CGFloat(defaults.object(forKey: namespacedKey(.subtitleFontSize)) as? Int ?? 28)
        subtitleIsBold = defaults.object(forKey: namespacedKey(.subtitleBold)) as? Bool ?? false

        isThisDeviceTheSyncServer = defaults.object(forKey: namespacedKey(.syncIsServer)) as? Bool ?? false
        syncServerHostnameOrIpAddress = defaults.string(forKey: namespacedKey(.syncServerHost)) ?? ""
        let savedPort = defaults.integer(forKey: namespacedKey(.syncPort))
        syncListeningPortNumber = savedPort == 0 ? 10000 : UInt16(clamping: savedPort)
        let drift = defaults.integer(forKey: namespacedKey(.syncDriftThresholdMs))
        syncDriftThresholdMilliseconds = drift == 0 ? 20 : drift
        let latency = defaults.integer(forKey: namespacedKey(.syncLatencyMs))
        syncLatencyMilliseconds = latency == 0 ? 167 : latency
        let ignore = defaults.integer(forKey: namespacedKey(.syncIgnoreThresholdMs))
        syncIgnoreThresholdMilliseconds = ignore == 0 ? 2000 : ignore

        brokerIsEnabled = defaults.object(forKey: namespacedKey(.brokerEnabled)) as? Bool ?? false
        brokerURLString = defaults.string(forKey: namespacedKey(.brokerURL)) ?? ""
        brokerClientId = defaults.string(forKey: namespacedKey(.brokerClientId)) ?? "xos-\(sessionId.prefix(8))"
        mediaPlayerIdentifierForBroker = defaults.string(forKey: namespacedKey(.mediaPlayerId)) ?? defaultMediaPlayerIdentifier(for: sessionId)
        let interval = defaults.double(forKey: namespacedKey(.brokerIntervalSeconds))
        brokerPostIntervalSeconds = interval > 0 ? interval : 0.5
    }

    private func defaultMediaPlayerIdentifier(for sessionId: String) -> String {
        let compact = sessionId.replacingOccurrences(of: "-", with: "")
        let hexPrefix = String(compact.prefix(4))
        if let value = Int(hexPrefix, radix: 16), value > 0 {
            return String(value)
        }
        return "1"
    }

    // MARK: Public API
    func onAppearStartPlayback() {
        Task { await loadPlaylistAndPreparePlaybackThenStart() }
        setupSyncNetworkingIfConfigured()
        setupBrokerIfConfigured()
    }

    func onAppBecameActive() {
        // Recreate server/client + timers after app returns
        setupSyncNetworkingIfConfigured()
    }

    func onSettingsSheetClosed() {
        // When the settings sheet is dismissed, reset sync
        setupSyncNetworkingIfConfigured()
    }

    func openSettingsSheet() { isShowingSettingsSheet = true }
    func toggleSettingsSheet() { isShowingSettingsSheet.toggle() }

    func saveSettingsAndReload() {
        persist(userEditablePlaylistIdentifier, for: .playlistIdentifier)
        persist(userEditableXOSApiEndpointBase, for: .xosApiEndpointBase)
        Task { await loadPlaylistAndPreparePlaybackThenStart() }
    }

    func clearAllCachedData() {
        do {
            try FileManager.default.removeItem(at: cacheDirectory())
        } catch { /* ignore if nothing to remove */ }
        Task { await loadPlaylistAndPreparePlaybackThenStart() }
    }

    // MARK: Loading + Caching
    private func loadPlaylistAndPreparePlaybackThenStart() async {
        isLoadingPlaylistAndVideos = true
        isOfflineWithNoCachedData = false
        removePlaybackObserversAndStop()

        let playlistId = userEditablePlaylistIdentifier
        do {
            let playlistResponse = try await fetchPlaylistPreferCache(playlistIdentifier: playlistId)
            self.lastLoadedPlaylist = playlistResponse
            let playerItems = try await prepareLocalPlayerItemsFrom(playlistResponse: playlistResponse)
            await configurePlayerQueueWith(itemsToPlayInOrder: playerItems)
            avQueuePlayer.play()
            isLoadingPlaylistAndVideos = false
        } catch FetchError.noInternetAndNoCache {
            isOfflineWithNoCachedData = true
            isLoadingPlaylistAndVideos = false
        } catch {
            // If something else failed, try showing cached playlist if available
            if let cached = try? loadCachedPlaylist(playlistIdentifier: playlistId) {
                do {
                    self.lastLoadedPlaylist = cached.playlist
                    let playerItems = try await prepareLocalPlayerItemsFrom(playlistResponse: cached.playlist)
                    await configurePlayerQueueWith(itemsToPlayInOrder: playerItems)
                    avQueuePlayer.play()
                    isLoadingPlaylistAndVideos = false
                } catch {
                    isOfflineWithNoCachedData = true
                    isLoadingPlaylistAndVideos = false
                }
            } else {
                isOfflineWithNoCachedData = true
                isLoadingPlaylistAndVideos = false
            }
        }
    }

    private enum FetchError: Error { case noInternetAndNoCache }

    private func fetchPlaylistPreferCache(playlistIdentifier: String) async throws -> XOSPlaylistResponse {
        // Try network first; on failure, fall back to cache; if no cache, throw
        if let networkPlaylist = try? await fetchPlaylistFromNetwork(playlistIdentifier: playlistIdentifier) {
            try savePlaylistToCache(networkPlaylist, playlistIdentifier: playlistIdentifier)
            return networkPlaylist
        }
        if let cached = try? loadCachedPlaylist(playlistIdentifier: playlistIdentifier) {
            return cached.playlist
        }
        throw FetchError.noInternetAndNoCache
    }

    private func fetchPlaylistFromNetwork(playlistIdentifier: String) async throws -> XOSPlaylistResponse {
        let urlString = xosPlaylistEndpoint + "\(playlistIdentifier)/"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(XOSPlaylistResponse.self, from: data)
    }

    private func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let appDir = base.appendingPathComponent("XOSMediaCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir
    }

    private func playlistDirectory(playlistIdentifier: String) -> URL {
        let dir = cacheDirectory().appendingPathComponent("playlist_\(playlistIdentifier)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func playlistJSONPath(playlistIdentifier: String) -> URL {
        playlistDirectory(playlistIdentifier: playlistIdentifier).appendingPathComponent("playlist.json")
    }

    private func savePlaylistToCache(_ playlist: XOSPlaylistResponse, playlistIdentifier: String) throws {
        let cached = CachedPlaylist(fetchedAt: Date(), playlist: playlist)
        let data = try JSONEncoder().encode(cached)
        try data.write(to: playlistJSONPath(playlistIdentifier: playlistIdentifier), options: .atomic)
    }

    private func loadCachedPlaylist(playlistIdentifier: String) throws -> CachedPlaylist {
        let data = try Data(contentsOf: playlistJSONPath(playlistIdentifier: playlistIdentifier))
        return try JSONDecoder().decode(CachedPlaylist.self, from: data)
    }

    private func localFileURLForRemoteResource(_ remoteString: String, playlistIdentifier: String) -> URL {
        let fileName = URL(string: remoteString)?.lastPathComponent ?? UUID().uuidString
        return playlistDirectory(playlistIdentifier: playlistIdentifier).appendingPathComponent(fileName)
    }

    private func ensureFileCached(from remoteString: String, playlistIdentifier: String) async throws -> URL {
        let localUrl = localFileURLForRemoteResource(remoteString, playlistIdentifier: playlistIdentifier)
        if FileManager.default.fileExists(atPath: localUrl.path) {
            return localUrl
        }
        guard let remoteUrl = URL(string: remoteString) else { throw URLError(.badURL) }
        let (tempUrl, response) = try await URLSession.shared.download(from: remoteUrl)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: tempUrl, to: localUrl)
        return localUrl
    }

    private func prepareLocalPlayerItemsFrom(playlistResponse: XOSPlaylistResponse) async throws -> [AVPlayerItem] {
        let playlistId = userEditablePlaylistIdentifier
        var items: [AVPlayerItem] = []
        subtitleCuesByLocalVideoURL.removeAll()
        for label in playlistResponse.playlist_labels {
            guard let resourceString = label.resource, !resourceString.isEmpty else { continue }
            do {
                let localVideoUrl = try await ensureFileCached(from: resourceString, playlistIdentifier: playlistId)
                if let subtitlesUrlString = label.subtitles, !subtitlesUrlString.isEmpty,
                   let localSubtitleUrl = try? await ensureFileCached(from: subtitlesUrlString, playlistIdentifier: playlistId),
                   let data = try? Data(contentsOf: localSubtitleUrl) {
                    subtitleCuesByLocalVideoURL[localVideoUrl] = WebVTTParser.parseWebVTT(from: data)
                }
                let asset = AVURLAsset(url: localVideoUrl)
                print("Preparing to play: \(localVideoUrl.lastPathComponent)")
                let item = AVPlayerItem(asset: asset)
                items.append(item)
            } catch {
                continue
            }
        }
        return items
    }

    // MARK: Player Setup
    private func configurePlayerQueueWith(itemsToPlayInOrder: [AVPlayerItem]) async {
        removePlaybackObserversAndStop()

        originalQueueItems = itemsToPlayInOrder

        // Reuse the existing player instance
        let player = avQueuePlayer
        player.removeAllItems()
        player.actionAtItemEnd = .advance
        player.isMuted = isPlaybackMuted
        itemsToPlayInOrder.forEach { player.insert($0, after: nil) }

        addEndOfQueueObserverToLoop()
        setupPeriodicPlayerTimeObserverForSubtitles()
    }

    private func removePlaybackObserversAndStop() {
        avQueuePlayer.pause()
        avQueuePlayer.removeAllItems()

        if let token = playerTimeObserverToken {
            avQueuePlayer.removeTimeObserver(token)
            playerTimeObserverToken = nil
        }
        if let endToken = endOfQueueObserverToken {
            NotificationCenter.default.removeObserver(endToken)
            endOfQueueObserverToken = nil
        }
        originalQueueItems.removeAll()
    }

    private func addEndOfQueueObserverToLoop() {
        endOfQueueObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.syncLockedIndex = nil

                // If the item that finished was the last in the queue, rebuild it.
                let items = self.avQueuePlayer.items()
                if let finishedItem = self.avQueuePlayer.currentItem, let last = items.last, finishedItem == last {
                    // iOS
                    self.rebuildQueueAndPlay()
                } else if self.avQueuePlayer.items().isEmpty {
                    // macOS
                    self.rebuildQueueAndPlay()
                }
            }
        }
    }

    private func rebuildQueueAndPlay() {
        let newItems = self.originalQueueItems.map { AVPlayerItem(asset: $0.asset) }
        newItems.forEach { self.avQueuePlayer.insert($0, after: nil) }

        // If the queue is truly empty (some iOS builds), advance once to load the first item
        if self.avQueuePlayer.currentItem == nil {
            self.avQueuePlayer.advanceToNextItem()
        }

        self.avQueuePlayer.play()
        self.avQueuePlayer.isMuted = self.isPlaybackMuted
        self.postPlaybackStatus()
    }

    // MARK: Subtitles + Sync helpers (moved from extension)
    private func setupPeriodicPlayerTimeObserverForSubtitles() {
        if let token = playerTimeObserverToken {
            avQueuePlayer.removeTimeObserver(token)
            playerTimeObserverToken = nil
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        playerTimeObserverToken = avQueuePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.showSubtitlesIfAvailable else { self.currentlyVisibleSubtitleText = ""; return }
                guard let currentItem = self.avQueuePlayer.currentItem else { self.currentlyVisibleSubtitleText = ""; return }
                if let asset = currentItem.asset as? AVURLAsset {
                    let seconds = CMTimeGetSeconds(time)
                    let cues = self.subtitleCuesByLocalVideoURL[asset.url] ?? []
                    if let cue = cues.first(where: { seconds >= $0.start && seconds <= $0.end }) {
                        self.currentlyVisibleSubtitleText = cue.text
                    } else {
                        self.currentlyVisibleSubtitleText = ""
                    }
                } else {
                    self.currentlyVisibleSubtitleText = ""
                }
            }
        }
    }

    private func setupSyncNetworkingIfConfigured() {
        // Tear down old things cleanly
        syncClient?.stop(); syncClient = nil
        serverTicker?.invalidate(); serverTicker = nil
        syncServer?.stop(); syncServer = nil

        if isThisDeviceTheSyncServer {
            guard let server = SimpleSyncServer(port: syncListeningPortNumber) else {
                // Optional: surface an error state in UI
                print("Failed to bind UDP listener on port \(syncListeningPortNumber)")
                return
            }
            syncServer = server

            serverTicker = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(handleServerTick), userInfo: nil, repeats: true)
        } else if !syncServerHostnameOrIpAddress.isEmpty {
            let client = SimpleSyncClient(serverHost: syncServerHostnameOrIpAddress, port: syncListeningPortNumber)
            client.onReceiveStateString = { [weak self] state in self?.handleServerSyncMessage(stateString: state) }
            client.start()
            syncClient = client
        }
    }

    @objc private func handleServerTick() {
        // This class is @MainActor, so we're on the main actor here.
        let index = self.currentPlaylistIndex() ?? -1
        let positionMs = self.avQueuePlayer.currentItem != nil ? Int((self.avQueuePlayer.currentTime().seconds * 1000).rounded()) : 0
        let state = "\(index),\(positionMs)"
        // print("Sync: \(state)")
        self.syncServer?.broadcast(stateString: state)
    }

    private func handleServerSyncMessage(stateString: String) {
        // Expect "index,positionMs"
        let parts = stateString.split(separator: ",").map(String.init)
        guard parts.count == 2,
              let serverIndex = Int(parts[0]),
              let serverMs32 = Int(parts[1]) else { return }

        // If we’re locked to this index, don’t even check drift.
        if let locked = syncLockedIndex, locked == serverIndex {
            return
        }

        let now = avQueuePlayer.currentTime()
        let clientSeconds = now.seconds
        guard clientSeconds.isFinite, clientSeconds >= 0 else { return }
        let clientMs = Int64((clientSeconds * 1000.0).rounded())
        let serverMs = Int64(serverMs32)

        if let clientIndex = currentPlaylistIndex(), clientIndex != serverIndex {
            // Different item: jump and clear any stale lock
            syncLockedIndex = nil
            jumpToPlaylistIndex(serverIndex)
        }

        let drift = abs(clientMs - serverMs)
        print("Drift: \(drift) (\(clientMs) - \(serverMs))")

        // If we’re inside threshold, lock for the rest of this track
        if drift <= Int64(syncDriftThresholdMilliseconds) {
            syncLockedIndex = serverIndex
            return
        }

        // Otherwise, apply correction as before
        let targetMs = serverMs + Int64(syncLatencyMilliseconds)
        if let duration = avQueuePlayer.currentItem?.asset.duration, duration.isNumeric {
            let durationMs = Int64((CMTimeGetSeconds(duration) * 1000.0).rounded())
            if (durationMs - targetMs) >= Int64(syncIgnoreThresholdMilliseconds),
               targetMs < durationMs {
                let newSeconds = Double(targetMs) / 1000.0
                avQueuePlayer.seek(
                    to: CMTime(seconds: newSeconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        }
    }

    private func currentPlaylistIndex() -> Int? {
        guard let currentItem = avQueuePlayer.currentItem else { return nil }
        // Try to identify the current item's asset URL (works for AVURLAsset-backed items)
        let currentURL: URL? = {
            if let asset = currentItem.asset as? AVURLAsset { return asset.url }
            return nil
        }()
        // Prefer matching against the original full playlist order so index doesn't reset to 0 as items are popped from the queue.
        if let currentURL {
            for (idx, item) in originalQueueItems.enumerated() {
                if let url = (item.asset as? AVURLAsset)?.url, url == currentURL {
                    return idx
                }
            }
        }
        // Fallback: best-effort by finding the current item in the remaining queue
        let remainingItems = avQueuePlayer.items()
        if let idxInRemaining = remainingItems.firstIndex(of: currentItem) {
            // Map remaining index to original index by finding the first matching asset in the original list from the start of remaining
            if let firstRemainingURL = (remainingItems.first?.asset as? AVURLAsset)?.url,
               let startIndex = originalQueueItems.firstIndex(where: { ( $0.asset as? AVURLAsset)?.url == firstRemainingURL }) {
                return startIndex + idxInRemaining
            }
        }
        return nil
    }

    private func jumpToPlaylistIndex(_ index: Int) {
        syncLockedIndex = nil                           // <— clear lock if we jump
        let items = avQueuePlayer.items()
        guard index >= 0 && index < items.count else { return }
        for _ in 0..<index { avQueuePlayer.advanceToNextItem() }
    }

    // Internal State
    private var originalQueueItems: [AVPlayerItem] = []
    private var endOfQueueObserverToken: Any?

    private func setupBrokerIfConfigured() {
        brokerTicker?.invalidate(); brokerTicker = nil

        let cfg = BrokerConfig(
            isEnabled: brokerIsEnabled,
            urlString: brokerURLString,
            clientId: brokerClientId,
            mediaPlayerId: mediaPlayerIdentifierForBroker,
            postIntervalSeconds: brokerPostIntervalSeconds
        )

        if brokerPublisher == nil {
            brokerPublisher = MQTTBrokerPublisher(config: cfg)
        } else {
            brokerPublisher?.update(config: cfg)
        }

        if cfg.isEnabled {
            brokerPublisher?.start()
            startBrokerTicker(interval: cfg.postIntervalSeconds)
            postLifecycleEventStarted()
        } else {
            brokerPublisher?.stop()
        }
    }

    private func startBrokerTicker(interval: Double) {
        brokerTicker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.postPlaybackStatus()
        }
    }

    private func postLifecycleEventStarted() {
        let payload: [String: Any] = [
            "datetime": ISO8601DateFormatter().string(from: Date()),
            "event": "player_started",
            "playlist_id": Int(userEditablePlaylistIdentifier) ?? 1,
            "media_player_id": Int(mediaPlayerIdentifierForBroker) ?? 1
        ]
        brokerPublisher?.publishStatus(payload)
    }

    private func currentDurationMilliseconds() -> Int {
        if let dur = avQueuePlayer.currentItem?.asset.duration, dur.isNumeric {
            return Int((CMTimeGetSeconds(dur) * 1000.0).rounded())
        }
        return 0
    }

    private func postPlaybackStatus() {
        // Build status similar to Python payload
        let idx = currentPlaylistIndex() ?? -1
        let posSeconds = avQueuePlayer.currentTime().seconds
        let durMs = currentDurationMilliseconds()
        let posFraction: Double = {
            guard durMs > 0 else { return 0.0 }
            let ms = Int((posSeconds * 1000.0).rounded())
            return max(0.0, min(1.0, Double(ms) / Double(durMs)))
        }()

        var currentName: String = ""
        if let asset = avQueuePlayer.currentItem?.asset as? AVURLAsset {
            currentName = asset.url.lastPathComponent
        }

        // Derive label_id from the playlist at current index
        let labelIdValue: Any = {
            guard let playlist = lastLoadedPlaylist, idx >= 0, idx < playlist.playlist_labels.count else { return NSNull() }
            let labelId = playlist.playlist_labels[idx].label?.id
            return labelId as Any? ?? NSNull()
        }()

        let payload: [String: Any] = [
            "datetime": ISO8601DateFormatter().string(from: Date()),
            "playlist_id": Int(userEditablePlaylistIdentifier) ?? 1,
            "media_player_id": Int(mediaPlayerIdentifierForBroker) ?? 1,
            "label_id": labelIdValue,
            "playlist_position": idx,
            "playback_position": posFraction,
            "dropped_audio_frames": 0,
            "dropped_video_frames": 0,
            "duration": durMs,
            "player_volume": NSNull(), // not available cross-platform without extra APIs
            "system_volume": NSNull(),
            "current_item": currentName
        ]

        brokerPublisher?.publishStatus(payload)
    }

}

// MARK: - Views

struct MediaPlayerRootView: View {
    let sessionId: String
    @StateObject private var viewModel: MediaPlayerViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(sessionId: String) {
        self.sessionId = sessionId
        _viewModel = StateObject(wrappedValue: MediaPlayerViewModel(sessionId: sessionId))
    }

    var body: some View {
        ZStack {
            if viewModel.isLoadingPlaylistAndVideos {
                loadingStateView
            } else if viewModel.isOfflineWithNoCachedData {
                noInternetStateView
            } else {
                playerWithOverlays
            }
        }
        .task { viewModel.onAppearStartPlayback() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                viewModel.onAppBecameActive()
            }
        }
#if os(tvOS)
        .fullScreenCover(isPresented: $viewModel.isShowingSettingsSheet) {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                SettingsSheetView(
                    playlistIdentifier: $viewModel.userEditablePlaylistIdentifier,
                    xosApiEndpointBase: $viewModel.userEditableXOSApiEndpointBase,
                    isPlaybackMuted: $viewModel.isPlaybackMuted,
                    videoControlsEnabled: $viewModel.videoControlsEnabled,
                    sessionIdentifier: viewModel.sessionId,
                    onSaveAndReload: { viewModel.saveSettingsAndReload() },
                    onClearCache: { viewModel.clearAllCachedData() },
                    extraContent: { SyncAndSubtitleSettings(viewModel: viewModel) }
                )
                .frame(maxWidth: 1180)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(60)
            }
        }
        .onChange(of: viewModel.isShowingSettingsSheet) { isPresented in
            if !isPresented {
                viewModel.onSettingsSheetClosed()
            }
        }
#else
        .sheet(isPresented: $viewModel.isShowingSettingsSheet) {
#if os(iOS)
            GeometryReader { proxy in
                let minWidth = min(1080, proxy.size.width)
                SettingsSheetView(
                    playlistIdentifier: $viewModel.userEditablePlaylistIdentifier,
                    xosApiEndpointBase: $viewModel.userEditableXOSApiEndpointBase,
                    isPlaybackMuted: $viewModel.isPlaybackMuted,
                    videoControlsEnabled: $viewModel.videoControlsEnabled,
                    sessionIdentifier: viewModel.sessionId,
                    onSaveAndReload: { viewModel.saveSettingsAndReload() },
                    onClearCache: { viewModel.clearAllCachedData() },
                    extraContent: { SyncAndSubtitleSettings(viewModel: viewModel) }
                )
                .presentationDetents([.large, .large])
                .frame(width: minWidth)
            }
#else
            SettingsSheetView(
                playlistIdentifier: $viewModel.userEditablePlaylistIdentifier,
                xosApiEndpointBase: $viewModel.userEditableXOSApiEndpointBase,
                isPlaybackMuted: $viewModel.isPlaybackMuted,
                videoControlsEnabled: $viewModel.videoControlsEnabled,
                sessionIdentifier: viewModel.sessionId,
                onSaveAndReload: { viewModel.saveSettingsAndReload() },
                onClearCache: { viewModel.clearAllCachedData() },
                extraContent: { SyncAndSubtitleSettings(viewModel: viewModel) }
            )
            .presentationDetents([.large, .large])
            .frame(width: 1080)
#endif
        }
        .onChange(of: viewModel.isShowingSettingsSheet) { isPresented in
            if !isPresented {
                viewModel.onSettingsSheetClosed()
            }
        }
#endif
        .modifier(FullscreenWindowModifier())
    }

    private var loadingStateView: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(2)
                        .tint(.gray)
                        .padding()
                    Text("Loading...")
                        .foregroundStyle(.white)
                }
                .frame(height: proxy.size.height / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleSettingsSheet() }
#if os(tvOS)
        .focusable(true)
        .onLongPressGesture { viewModel.toggleSettingsSheet() }
#endif
    }

    private var noInternetStateView: some View {
        GeometryReader { proxy in
            ZStack() {
                VStack() {
                    Image(systemName: "wifi.exclamationmark")
                        .resizable()
                        .scaledToFit()
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .frame(height: proxy.size.height * 0.2)
                        .padding()
                    Text("Please connect to ACMI Wi-Fi")
                        .foregroundStyle(.white)
                }
                .frame(height: proxy.size.height / 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleSettingsSheet() }
#if os(tvOS)
        .focusable(true)
        .onLongPressGesture { viewModel.toggleSettingsSheet() }
#endif
    }
}

struct SettingsSheetView<ExtraContent: View>: View {
    @Binding var playlistIdentifier: String
    @Binding var xosApiEndpointBase: String
    @Binding var isPlaybackMuted: Bool
    @Binding var videoControlsEnabled: Bool
    let sessionIdentifier: String
    var onSaveAndReload: () -> Void
    var onClearCache: () -> Void
    var extraContent: () -> ExtraContent
    @Environment(\.dismiss) private var dismiss

    init(playlistIdentifier: Binding<String>, xosApiEndpointBase: Binding<String>, isPlaybackMuted: Binding<Bool>, videoControlsEnabled: Binding<Bool>, sessionIdentifier: String, onSaveAndReload: @escaping () -> Void, onClearCache: @escaping () -> Void, extraContent: @escaping () -> ExtraContent = { EmptyView() as! ExtraContent }) {
        self._playlistIdentifier = playlistIdentifier
        self._xosApiEndpointBase = xosApiEndpointBase
        self._isPlaybackMuted = isPlaybackMuted
        self._videoControlsEnabled = videoControlsEnabled
        self.sessionIdentifier = sessionIdentifier
        self.onSaveAndReload = onSaveAndReload
        self.onClearCache = onClearCache
        self.extraContent = extraContent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist Settings") {
                    TextField("Playlist ID", text: $playlistIdentifier)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                    TextField("API endpoint base", text: $xosApiEndpointBase)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                    Toggle("Mute playback", isOn: $isPlaybackMuted)
                    Toggle("Show video controls", isOn: $videoControlsEnabled)
                    LabeledContent("Session ID") {
                        Text(sessionIdentifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Cache") {
                    Button("Clear Cached Playlist and Videos") { onClearCache(); dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                extraContent()
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Reload") { onSaveAndReload(); dismiss() }
                }
            }
            .padding()
        }
    }
}

// MARK: - Fullscreen Window Modifier (macOS)

struct FullscreenWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

import Network

// MARK: - Subtitle Model and Parser

struct SubtitleCue: Identifiable { let id = UUID(); let start: Double; let end: Double; let text: String }

enum WebVTTParser {
    static func parseWebVTT(from data: Data) -> [SubtitleCue] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        var cues: [SubtitleCue] = []
        let lines = raw.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.contains("-->"), let cue = parseCue(at: &i, lines: lines) { cues.append(cue) }
            i += 1
        }
        return cues
    }

    private static func parseCue(at index: inout Int, lines: [String]) -> SubtitleCue? {
        // Expect time range line at current index
        let timing = lines[index]
        let parts = timing.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces))
        let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
        var textLines: [String] = []
        var j = index + 1
        while j < lines.count {
            let t = lines[j]
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            textLines.append(t)
            j += 1
        }
        index = j
        return SubtitleCue(start: start, end: end, text: textLines.joined(separator: ""))
    }

    private static func parseTimestamp(_ s: String) -> Double {
        // Supports "HH:MM:SS.mmm" or "MM:SS.mmm"
        let comps = s.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard comps.count >= 2 else { return 0 }
        let last = comps.last ?? "0"
        let seconds = Double(last) ?? 0
        let minutes = Double(comps[comps.count - 2]) ?? 0
        let hours = comps.count == 3 ? Double(comps[0]) ?? 0 : 0
        return hours * 3600 + minutes * 60 + seconds
    }
}

// MARK: - Sync Networking (UDP with NWConnection)

final class SimpleSyncServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "xos.sync.server")
    private let port: NWEndpoint.Port
    private var isRunning = false

    // Keep inbound client connections (no extra outbound sockets)
    private var clientConnections = Set<ObjectIdentifier>()
    private var connectionsById: [ObjectIdentifier: NWConnection] = [:]

    init?(port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let params = NWParameters.udp
        // You can leave this false; it’s not needed anymore
        // params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: nwPort) else { return nil }
        self.listener = listener
        self.port = nwPort

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let bound = self.listener.port?.rawValue ?? self.port.rawValue
                print("Server ready on UDP port \(bound)")
            case .failed(let err):
                print("Listener failed: \(err)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let oid = ObjectIdentifier(connection)
            self.connectionsById[oid] = connection
            self.clientConnections.insert(oid)

            connection.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .failed, .cancelled:
                    self.connectionsById[oid]?.cancel()
                    self.connectionsById[oid] = nil
                    self.clientConnections.remove(oid)
                default:
                    break
                }
            }

            // Keep receiving to keep the connection alive (UDP is message-oriented)
            self.setupReceive(on: connection)
            connection.start(queue: self.queue)
        }

        listener.start(queue: queue)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        listener.cancel()
        for (_, conn) in connectionsById { conn.cancel() }
        connectionsById.removeAll()
        clientConnections.removeAll()
        isRunning = false
    }

    private func setupReceive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, _ in
            guard let self else { return }
            // Just loop; we don’t need to discover endpoints anymore
            self.setupReceive(on: connection)
        }
    }

    func broadcast(stateString: String) {
        let payload = Data(stateString.utf8)
        for oid in clientConnections {
            guard let conn = connectionsById[oid] else { continue }
            conn.send(content: payload, completion: .contentProcessed { _ in })
        }
    }
}


final class SimpleSyncClient {
    private let serverHost: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "xos.sync.client")
    private var connection: NWConnection?
    var onReceiveStateString: ((String) -> Void)?

    init(serverHost: String, port: UInt16) {
        self.serverHost = serverHost
        self.port = port
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        // Force IPv4 by constructing an IPv4Address from the string.
        // Accept either a dotted-quad ("192.168.1.10") or a hostname you resolve yourself.
        guard let ipv4 = IPv4Address(serverHost) else {
            print("SimpleSyncClient: serverHost must be an IPv4 address like 192.168.1.10")
            return
        }
        let host: NWEndpoint.Host = .ipv4(ipv4)

        let params = NWParameters.udp
        // (Optional) reuse okay if you’re bouncing the client
        params.allowLocalEndpointReuse = true

        let connection = NWConnection(host: host, port: nwPort, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { state in
            print("Client state: \(state) on port \(self.port)")
        }
        connection.start(queue: queue)

        sendHello()
        receiveLoop()
    }

    private func sendHello() {
        connection?.send(content: Data("hello".utf8), completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, _, _ in
            if let data, let str = String(data: data, encoding: .utf8) {
                self?.onReceiveStateString?(str)
            }
            self?.receiveLoop()
        }
    }

    func stop() { connection?.cancel(); connection = nil }
}

// MARK: - Subtitle Overlay View

struct SubtitleOverlayView: View {
    let text: String
    let fontSize: CGFloat
    let isBold: Bool

    var body: some View {
        VStack { Spacer() ; subtitleBubble ; Spacer().frame(height: 20) }
            .padding(.horizontal, 40)
            .allowsHitTesting(false)
    }

    private var subtitleBubble: some View {
        Text(text)
            .font(isBold ? .system(size: fontSize, weight: .bold) : .system(size: fontSize, weight: .regular))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(text.isEmpty ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: text)
    }
}

// MARK: - UI wiring updates

extension MediaPlayerRootView {
    @ViewBuilder
    var playerWithOverlays: some View {
        ZStack {
#if os(macOS)
            VideoSurface(player: viewModel.avQueuePlayer, controlsEnabled: viewModel.videoControlsEnabled)
                .ignoresSafeArea()
#else
            VideoSurface(
                player: viewModel.avQueuePlayer,
                controlsEnabled: viewModel.videoControlsEnabled,
                onLongPress: { viewModel.openSettingsSheet() }
            )
                .ignoresSafeArea()
#endif

            if viewModel.showSubtitlesIfAvailable {
                SubtitleOverlayView(text: viewModel.currentlyVisibleSubtitleText,
                                    fontSize: viewModel.subtitleFontPointSize,
                                    isBold: viewModel.subtitleIsBold)
            }

#if !os(macOS)
            if !viewModel.videoControlsEnabled {
                LongPressSettingsOverlay(
                    isEnabled: true,
                    onLongPress: { viewModel.openSettingsSheet() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
#endif
        }
        .contentShape(Rectangle())
        .onLongPressGesture {
#if os(macOS)
            guard !viewModel.videoControlsEnabled else { return }
#endif
            viewModel.openSettingsSheet()
        }
#if os(macOS)
        .background(
            MacSettingsShortcutHandler(
                isEnabled: !viewModel.isShowingSettingsSheet,
                allowsSpaceToOpenSettings: !viewModel.videoControlsEnabled
            ) {
                viewModel.openSettingsSheet()
            }
        )
#endif
    }
}

// Sync + Subtitle controls inside the sheet
struct SyncAndSubtitleSettings: View {
    @ObservedObject var viewModel: MediaPlayerViewModel

    var body: some View {
        Section("Subtitles") {
            Toggle("Show subtitles if available", isOn: $viewModel.showSubtitlesIfAvailable)
#if !os(tvOS)
            Stepper(value: $viewModel.subtitleFontPointSize, in: 12...72, step: 2) {
                Text("Font size: \(Int(viewModel.subtitleFontPointSize))")
            }
#else
            Picker("Font size", selection: $viewModel.subtitleFontPointSize) {
                ForEach(Array(stride(from: 12, through: 72, by: 2)), id: \.self) { size in
                    Text("\(Int(size))").tag(size)
                }
            }
            .pickerStyle(.menu)
#endif

            Toggle("Bold text", isOn: $viewModel.subtitleIsBold)
        }

        Section("Multi-device Sync") {
            Toggle("This device is the sync server", isOn: $viewModel.isThisDeviceTheSyncServer)

            TextField("Server hostname/IP (for clients)", text: $viewModel.syncServerHostnameOrIpAddress)
                .autocorrectionDisabled(true)
#if os(iOS)
            .autocapitalization(.none)
#endif

#if os(tvOS)
            // tvOS: use Pickers instead of Steppers
            Picker("Port", selection: Binding(get: { Int(viewModel.syncListeningPortNumber) }, set: { newVal in
                let clamped = max(1000, min(65500, newVal))
                viewModel.syncListeningPortNumber = UInt16(clamped)
            })) {
                // Offer a reasonable set of common ports plus current value if custom
                let ports: [Int] = [1000, 1883, 1884, 4222, 5672, 61613, 10000, 20000, 30000, 40000, 50000, 60000, 65500]
                ForEach(Array(Set(ports + [Int(viewModel.syncListeningPortNumber)])).sorted(), id: \.self) { p in
                    Text("\(p)").tag(p)
                }
            }

            Picker("Drift threshold (ms)", selection: $viewModel.syncDriftThresholdMilliseconds) {
                ForEach(Array(stride(from: 5, through: 500, by: 5)), id: \.self) { v in
                    Text("\(v)").tag(v)
                }
            }

            Picker("Sync latency (ms)", selection: $viewModel.syncLatencyMilliseconds) {
                ForEach(Array(stride(from: 0, through: 500, by: 5)), id: \.self) { v in
                    Text("\(v)").tag(v)
                }
            }

            Picker("Ignore threshold remaining (ms)", selection: $viewModel.syncIgnoreThresholdMilliseconds) {
                ForEach(Array(stride(from: 100, through: 10000, by: 100)), id: \.self) { v in
                    Text("\(v)").tag(v)
                }
            }
#else
            Stepper(value: Binding(get: { Int(viewModel.syncListeningPortNumber) }, set: { newVal in
                let clamped = max(1000, min(65500, newVal))
                viewModel.syncListeningPortNumber = UInt16(clamped)
            }), in: 1000...65500, step: 1) { Text("Port: \(viewModel.syncListeningPortNumber)") }
            Stepper(value: $viewModel.syncDriftThresholdMilliseconds, in: 5...500, step: 1) { Text("Drift threshold (ms): \(viewModel.syncDriftThresholdMilliseconds)") }
            Stepper(value: $viewModel.syncLatencyMilliseconds, in: 0...500, step: 1) { Text("Sync latency (ms): \(viewModel.syncLatencyMilliseconds)") }
            Stepper(value: $viewModel.syncIgnoreThresholdMilliseconds, in: 100...10000, step: 100) { Text("Ignore threshold remaining (ms): \(viewModel.syncIgnoreThresholdMilliseconds)") }
#endif

            Text("Clients: set the server hostname/IP and leave ‘This device is the sync server’ OFF. The client will auto-listen and adjust playback.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Message Broker (MQTT → amq.topic)") {
            Toggle("Enable broker publishing", isOn: $viewModel.brokerIsEnabled)

            TextField("Broker URL (mqtt[s]://user:pass@host:port)", text: $viewModel.brokerURLString)
                .autocorrectionDisabled(true)
#if os(iOS)
                .autocapitalization(.none)
#endif

            TextField("Client ID", text: $viewModel.brokerClientId)
                .autocorrectionDisabled(true)
#if os(iOS)
                .autocapitalization(.none)
#endif

            TextField("Media Player ID (topic suffix)", text: $viewModel.mediaPlayerIdentifierForBroker)
                .autocorrectionDisabled(true)
#if os(iOS)
                .autocapitalization(.none)
#endif
#if os(tvOS)
            Picker("Post interval (s)", selection: $viewModel.brokerPostIntervalSeconds) {
                ForEach(Array(stride(from: 0.1, through: 5.0, by: 0.1)), id: \.self) { v in
                    Text(String(format: "%.1f", v)).tag(v)
                }
            }
#else
            Stepper(value: $viewModel.brokerPostIntervalSeconds, in: 0.1...5.0, step: 0.1) {
                Text("Post interval: \(String(format: "%.1f", viewModel.brokerPostIntervalSeconds))s")
            }
#endif

            Text("Publishes JSON to topic mediaplayer.{id}. In RabbitMQ with the MQTT plugin, this maps to exchange amq.topic with routing key mediaplayer.{id}.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
private struct MacSettingsShortcutHandler: NSViewRepresentable {
    let isEnabled: Bool
    let allowsSpaceToOpenSettings: Bool
    let onOpenSettings: () -> Void

    func makeNSView(context: Context) -> ShortcutHandlingView {
        let view = ShortcutHandlingView()
        view.onOpenSettings = onOpenSettings
        view.isEnabled = isEnabled
        view.allowsSpaceToOpenSettings = allowsSpaceToOpenSettings
        return view
    }

    func updateNSView(_ nsView: ShortcutHandlingView, context: Context) {
        nsView.onOpenSettings = onOpenSettings
        nsView.isEnabled = isEnabled
        nsView.allowsSpaceToOpenSettings = allowsSpaceToOpenSettings
    }

    final class ShortcutHandlingView: NSView {
        var isEnabled = true
        var allowsSpaceToOpenSettings = true
        var onOpenSettings: () -> Void = {}
        private var keyDownMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateKeyDownMonitor()
        }

        deinit {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }
        }

        private func updateKeyDownMonitor() {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }

            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard self.isEnabled, event.window === self.window else { return event }
                guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else { return event }

                if Self.opensSettings(event, allowsSpace: self.allowsSpaceToOpenSettings) {
                    self.onOpenSettings()
                    return nil
                }

                return event
            }
        }

        private static func opensSettings(_ event: NSEvent, allowsSpace: Bool) -> Bool {
            switch event.keyCode {
            case 36:
                return true
            case 49:
                return allowsSpace
            default:
                return event.charactersIgnoringModifiers?.lowercased() == "s"
            }
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let controlsEnabled: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = controlsEnabled ? .floating : .none
        v.showsFullScreenToggleButton = false
        v.updatesNowPlayingInfoCenter = false
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.controlsStyle = controlsEnabled ? .floating : .none
    }
}
#else
struct LongPressSettingsOverlay: UIViewRepresentable {
    let isEnabled: Bool
    let onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress, isEnabled: isEnabled)
    }

    func makeUIView(context: Context) -> OverlayView {
        let view = OverlayView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isEnabled = isEnabled

        let longPressRecognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPressRecognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(longPressRecognizer)

        return view
    }

    func updateUIView(_ uiView: OverlayView, context: Context) {
        uiView.isEnabled = isEnabled
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onLongPress = onLongPress
    }

    final class OverlayView: UIView {
        var isEnabled = true

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            isEnabled && super.point(inside: point, with: event)
        }
    }

    final class Coordinator: NSObject {
        var onLongPress: () -> Void
        var isEnabled: Bool

        init(onLongPress: @escaping () -> Void, isEnabled: Bool) {
            self.onLongPress = onLongPress
            self.isEnabled = isEnabled
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, isEnabled else { return }
            onLongPress()
        }
    }
}

struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let controlsEnabled: Bool
    let onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress, controlsEnabled: controlsEnabled)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = controlsEnabled
        controller.videoGravity = .resizeAspect

        let longPressRecognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPressRecognizer.delegate = context.coordinator
        longPressRecognizer.cancelsTouchesInView = false
        controller.view.addGestureRecognizer(longPressRecognizer)

        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.controlsEnabled = controlsEnabled

        if controller.player !== player {
            controller.player = player
        }
        controller.showsPlaybackControls = controlsEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLongPress: () -> Void
        var controlsEnabled: Bool

        init(onLongPress: @escaping () -> Void, controlsEnabled: Bool) {
            self.onLongPress = onLongPress
            self.controlsEnabled = controlsEnabled
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - Previews

#Preview("Player Preview") {
    MediaPlayerRootView(sessionId: "preview-session")
        .background(Color.black)
}
