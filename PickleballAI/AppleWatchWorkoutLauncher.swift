import Foundation
@preconcurrency import HealthKit
import os

enum HealthMetricsSharing {
    static let defaultsKey = "shareAppleWatchHealthMetrics"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Uses HealthKit's supported handoff to launch or wake the companion Watch app
/// when a live session begins on iPhone.
@MainActor
final class AppleWatchWorkoutLauncher {
    static let shared = AppleWatchWorkoutLauncher()

    nonisolated private static let logger = Logger(subsystem: "com.pickleball.ai", category: "HealthKit")
    private let healthStore = HKHealthStore()

    func startWorkout() {
        guard HealthMetricsSharing.isEnabled, HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .pickleball
        configuration.locationType = .unknown
        healthStore.startWatchApp(with: configuration) { success, error in
            if let error {
                Self.logger.debug("Watch workout launch failed: \(error.localizedDescription, privacy: .public)")
            } else if !success {
                Self.logger.debug("Watch workout launch was unavailable")
            }
        }
    }
}
