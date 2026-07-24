import Foundation
@preconcurrency import HealthKit
import os

enum HealthMetricsSharing {
    static let defaultsKey = "shareAppleWatchHealthMetrics"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

enum WatchWorkoutStatus: Equatable {
    case idle
    case starting
    case waitingForHeartRate
    case tracking
    case disconnected
    case finalizing
    case failed(String)

    var message: String {
        switch self {
        case .idle: return "Apple Watch not connected"
        case .starting: return "Starting Apple Watch…"
        case .waitingForHeartRate: return "Waiting for a heart-rate reading…"
        case .tracking: return "Live from Apple Watch"
        case .disconnected: return "Apple Watch disconnected, reconnecting…"
        case .finalizing: return "Finalizing Apple Watch workout…"
        case .failed(let message): return message
        }
    }
}

enum AppleWatchWorkoutLaunchError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The Apple Watch workout could not be started. Make sure the Watch app is installed and your Watch is nearby."
    }
}

/// Uses HealthKit's supported handoff to launch or wake the companion Watch app
/// when a live session begins on iPhone.
@MainActor
final class AppleWatchWorkoutLauncher {
    static let shared = AppleWatchWorkoutLauncher()

    nonisolated private static let logger = Logger(subsystem: "com.pickleball.ai", category: "HealthKit")
    private let healthStore = HKHealthStore()

    func startWorkout(completion: @escaping (Result<Void, Error>) -> Void) {
        guard HealthMetricsSharing.isEnabled, HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(AppleWatchWorkoutLaunchError.unavailable))
            return
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .pickleball
        configuration.locationType = .unknown
        healthStore.startWatchApp(with: configuration) { success, error in
            Task { @MainActor in
                if let error {
                    Self.logger.debug("Watch workout launch failed: \(error.localizedDescription, privacy: .public)")
                    completion(.failure(error))
                } else if !success {
                    Self.logger.debug("Watch workout launch was unavailable")
                    completion(.failure(AppleWatchWorkoutLaunchError.unavailable))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
}
