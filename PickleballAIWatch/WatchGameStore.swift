import Foundation
import Combine
import WatchKit
import os

/// The watch's brain: owns the live game, drives the WC link, and persists the
/// in-progress game to disk so a relaunch mid-match restores it. The watch is
/// authoritative *during* a game; the phone is authoritative for *posting*.
@MainActor
final class WatchGameStore: ObservableObject {
    enum Phase: Equatable {
        case setup          // choosing target / serve before the first point
        case playing        // scoring in progress
        case gameOver       // a game just completed; new game or finish
    }

    @Published var phase: Phase = .setup
    /// The live game. `didSet` persists it and (when we're the origin) syncs.
    @Published private(set) var game = LiveMatchScore()

    private static let logger = Logger(subsystem: "com.pickleball.ai.watchapp", category: "Store")
    private let client = WatchConnectivityClient.shared

    private static let persistenceURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("live-game.json")
    }()

    init() {
        restore()
        client.onMessage = { [weak self] message in
            self?.handleInbound(message)
        }
        client.activate()
    }

    // MARK: Setup

    func setTarget(_ target: Int) {
        game.target = target
    }

    func toggleServe() {
        game.toggleServe()
        Haptics.play(.click)
        client.sendScore(game)
    }

    /// Begin scoring. Sends `startGame` so the phone opens/reuses a session.
    func startGame() {
        game.startedAt = Date()
        phase = .playing
        persist()
        client.sendCommand(.startGame(game))
        client.sendScore(game)
        Haptics.play(.start)
    }

    // MARK: Scoring

    func award(_ side: Side) {
        guard phase == .playing else { return }
        game.award(side)
        persist()
        client.sendScore(game)
        if game.isComplete {
            phase = .gameOver
            Haptics.play(.success)
            client.sendCommand(.endGame(game))
        } else {
            Haptics.play(.click)
        }
    }

    func undo() {
        guard !game.points.isEmpty else { return }
        game.undo()
        if phase == .gameOver { phase = .playing }
        persist()
        client.sendScore(game)
        Haptics.play(.directionUp)
    }

    // MARK: Game lifecycle

    /// Start another game in the same session, carrying settings forward.
    func newGame() {
        game = LiveMatchScore(serving: game.serving.opposite, target: game.target, winByTwo: game.winByTwo)
        phase = .playing
        persist()
        client.sendCommand(.newGame(game))
        client.sendScore(game)
        Haptics.play(.start)
    }

    /// Finish the whole session; the phone posts it.
    func finishSession() {
        client.sendCommand(.finishSession, immediately: true)
        resetToSetup()
        Haptics.play(.stop)
    }

    // MARK: Inbound (phone edits reflect back onto the watch)

    private func handleInbound(_ message: WatchSyncMessage) {
        switch message {
        case .score(let incoming):
            // Last-writer-wins: adopt only a strictly newer snapshot (ties broken
            // by start time) so a stale delivery can't clobber local scoring.
            let newer = incoming.seq > game.seq
                || (incoming.seq == game.seq && incoming.startedAt > game.startedAt)
            guard incoming.id == game.id || newer else { return }
            game = incoming
            if phase == .setup, !incoming.points.isEmpty { phase = .playing }
            if incoming.isComplete { phase = .gameOver }
            persist()
        case .command(let command):
            switch command {
            case .finishSession, .discardSession:
                resetToSetup()
            case .startGame(let s), .newGame(let s):
                game = s
                phase = .playing
                persist()
            case .endGame(let s):
                game = s
                phase = .gameOver
                persist()
            }
        }
    }

    /// Clears the live game and returns the wrist UI to setup. Shared by the
    /// watch's own Finish and by the phone ending or discarding the session.
    private func resetToSetup() {
        game = LiveMatchScore(target: game.target, winByTwo: game.winByTwo)
        phase = .setup
        clearPersistence()
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(game) else { return }
        try? data.write(to: Self.persistenceURL, options: .atomic)
    }

    private func restore() {
        guard
            let data = try? Data(contentsOf: Self.persistenceURL),
            let saved = try? JSONDecoder().decode(LiveMatchScore.self, from: data)
        else { return }
        game = saved
        if saved.isComplete {
            phase = .gameOver
        } else if !saved.points.isEmpty {
            phase = .playing
        }
    }

    private func clearPersistence() {
        try? FileManager.default.removeItem(at: Self.persistenceURL)
    }
}

/// Thin wrapper over `WKInterfaceDevice` haptics so views/store stay declarative.
enum Haptics {
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}
