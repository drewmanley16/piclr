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
    private let workout = WatchWorkoutManager.shared
    private var workoutObservation: AnyCancellable?

    var workoutIsActive: Bool { workout.isActive }
    var workoutIsFinishing: Bool { workout.isFinishing }
    var currentHeartRateBPM: Int? { workout.currentHeartRateBPM }
    var activeCaloriesKcal: Int? { workout.activeCaloriesKcal }
    var workoutErrorMessage: String? { workout.errorMessage }

    private static let persistenceURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("live-game.json")
    }()

    init() {
        restore()
        workoutObservation = workout.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        workout.start(at: game.startedAt)
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
        finishTrackedWorkout(postSession: true)
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
            case .finishSession:
                game = LiveMatchScore(target: game.target, winByTwo: game.winByTwo)
                phase = .setup
                clearPersistence()
            case .requestFinishWorkout:
                finishTrackedWorkout(postSession: false)
            case .requestLiveWorkoutMetrics:
                workout.sendCurrentMetrics()
            case .discardWorkout:
                workout.discard()
                game = LiveMatchScore(target: game.target, winByTwo: game.winByTwo)
                phase = .setup
                clearPersistence()
            case .workoutStarted, .liveWorkoutMetrics, .workoutFinished:
                break
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

    private func finishTrackedWorkout(postSession: Bool) {
        guard !workout.isFinishing else { return }
        workout.finish { [weak self] metrics in
            guard let self else { return }
            if let metrics {
                self.client.sendCommand(.workoutFinished(metrics, postSession: postSession), immediately: true)
            } else if postSession {
                self.client.sendCommand(.finishSession)
            } else {
                let now = Date()
                let emptyMetrics = WorkoutMetrics(
                    averageHeartRateBPM: nil,
                    maximumHeartRateBPM: nil,
                    activeCaloriesKcal: nil,
                    startedAt: self.game.startedAt,
                    endedAt: now
                )
                self.client.sendCommand(.workoutFinished(emptyMetrics, postSession: false), immediately: true)
            }
            self.game = LiveMatchScore(target: self.game.target, winByTwo: self.game.winByTwo)
            self.phase = .setup
            self.clearPersistence()
            Haptics.play(.stop)
        }
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
