import Combine
import Foundation
@preconcurrency import HealthKit
import WatchKit
import os

/// Owns the single HealthKit workout running on Apple Watch. The scoring UI is
/// intentionally independent: a denied permission or sensor failure never
/// prevents someone from keeping score.
@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    static let shared = WatchWorkoutManager()

    @Published private(set) var isActive = false
    @Published private(set) var isFinishing = false
    @Published private(set) var currentHeartRateBPM: Int?
    @Published private(set) var averageHeartRateBPM: Int?
    @Published private(set) var activeCaloriesKcal: Int?
    @Published private(set) var errorMessage: String?
    private(set) var startedAt: Date?

    nonisolated private static let logger = Logger(subsystem: "com.pickleball.ai.watchapp", category: "HealthKit")
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var pendingFinish: ((WorkoutMetrics?) -> Void)?
    private var isStarting = false

    static func pickleballConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .pickleball
        configuration.locationType = .unknown
        return configuration
    }

    func start(at startDate: Date = Date()) {
        start(configuration: Self.pickleballConfiguration(), at: startDate)
    }

    func start(configuration: HKWorkoutConfiguration, at startDate: Date = Date()) {
        if isActive {
            WatchConnectivityClient.shared.sendCommand(
                .workoutStarted(startedAt ?? startDate),
                immediately: true
            )
            sendCurrentMetrics()
            return
        }
        guard !isStarting, session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            failStart("Health data is unavailable on this Apple Watch.")
            return
        }

        isStarting = true
        let activityType = configuration.activityType
        let locationType = configuration.locationType
        let workout = HKObjectType.workoutType()
        let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        healthStore.requestAuthorization(toShare: [workout], read: [heartRate, activeEnergy]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                guard granted, error == nil else {
                    self.failStart("Allow Health access on Apple Watch to record heart rate and calories.")
                    return
                }
                let authorizedConfiguration = HKWorkoutConfiguration()
                authorizedConfiguration.activityType = activityType
                authorizedConfiguration.locationType = locationType
                self.begin(configuration: authorizedConfiguration, at: startDate)
            }
        }
    }

    func finish(completion: @escaping (WorkoutMetrics?) -> Void) {
        guard let session else {
            completion(nil)
            return
        }
        guard pendingFinish == nil else { return }

        isFinishing = true
        pendingFinish = completion
        let endDate = Date()
        if session.state == .stopped {
            finalize(at: endDate)
        } else {
            session.stopActivity(with: endDate)
        }
    }

    func discard() {
        let currentSession = session
        currentSession?.stopActivity(with: Date())
        builder?.discardWorkout()
        currentSession?.end()
        pendingFinish?(nil)
        reset()
    }

    func recoverActiveWorkout() {
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, error in
            Task { @MainActor in
                guard let self, let recovered, error == nil else { return }
                self.session = recovered
                self.builder = recovered.associatedWorkoutBuilder()
                self.session?.delegate = self
                self.builder?.delegate = self
                self.startedAt = recovered.startDate ?? Date()
                self.isActive = true
                WatchConnectivityClient.shared.sendCommand(
                    .workoutStarted(self.startedAt ?? Date()),
                    immediately: true
                )
                self.sendCurrentMetrics()
            }
        }
    }

    private func begin(configuration: HKWorkoutConfiguration, at startDate: Date) {
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            self.startedAt = startDate
            errorMessage = nil

            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard success, error == nil else {
                        self.failStart("The Apple Watch workout couldn't start.")
                        self.reset()
                        return
                    }
                    self.isActive = true
                    WatchConnectivityClient.shared.sendCommand(.workoutStarted(startDate), immediately: true)
                }
            }
        } catch {
            failStart("The workout couldn't start. Another workout may already be running.")
            Self.logger.error("workout start failed: \(error.localizedDescription, privacy: .public)")
            reset()
        }
    }

    private func updateStatistics(for collectedTypes: Set<HKSampleType>) {
        guard let builder else { return }
        let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!

        if collectedTypes.contains(heartRate),
           let statistics = builder.statistics(for: heartRate),
           let quantity = statistics.mostRecentQuantity() {
            let unit = HKUnit.count().unitDivided(by: .minute())
            currentHeartRateBPM = Int(quantity.doubleValue(for: unit).rounded())
            averageHeartRateBPM = statistics.averageQuantity().map {
                Int($0.doubleValue(for: unit).rounded())
            }
        }
        if collectedTypes.contains(activeEnergy),
           let quantity = builder.statistics(for: activeEnergy)?.sumQuantity() {
            activeCaloriesKcal = Int(quantity.doubleValue(for: .kilocalorie()).rounded())
        }
        sendCurrentMetrics()
    }

    func sendCurrentMetrics() {
        guard isActive else { return }
        WatchConnectivityClient.shared.sendLiveWorkoutMetrics(
            LiveWorkoutMetrics(
                heartRateBPM: currentHeartRateBPM,
                averageHeartRateBPM: averageHeartRateBPM,
                activeCaloriesKcal: activeCaloriesKcal
            )
        )
    }

    private func finalize(at endDate: Date) {
        guard let builder, let session else {
            pendingFinish?(nil)
            reset()
            return
        }

        builder.endCollection(withEnd: endDate) { [weak self] success, error in
            guard success, error == nil else {
                Task { @MainActor in
                    self?.pendingFinish?(nil)
                    self?.reset()
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read aggregate statistics only after HealthKit confirms that
                // collection has ended, so the final sensor samples are included.
                let metrics = self.finalMetrics(from: builder, session: session, endDate: endDate)
                builder.finishWorkout { [weak self] _, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            Self.logger.error("workout save failed: \(error.localizedDescription, privacy: .public)")
                            self.pendingFinish?(nil)
                        } else {
                            self.pendingFinish?(metrics)
                        }
                        session.end()
                        self.reset()
                    }
                }
            }
        }
    }

    private func finalMetrics(
        from builder: HKLiveWorkoutBuilder,
        session: HKWorkoutSession,
        endDate: Date
    ) -> WorkoutMetrics {
        let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let heartStats = builder.statistics(for: heartRate)
        let energyStats = builder.statistics(for: activeEnergy)
        return WorkoutMetrics(
            averageHeartRateBPM: heartStats?.averageQuantity().map { Int($0.doubleValue(for: heartUnit).rounded()) },
            maximumHeartRateBPM: heartStats?.maximumQuantity().map { Int($0.doubleValue(for: heartUnit).rounded()) },
            activeCaloriesKcal: energyStats?.sumQuantity().map { Int($0.doubleValue(for: .kilocalorie()).rounded()) },
            startedAt: startedAt ?? session.startDate ?? endDate,
            endedAt: endDate
        )
    }

    private func failStart(_ message: String) {
        errorMessage = message
        WatchConnectivityClient.shared.sendCommand(.workoutStartFailed(message), immediately: true)
    }

    private func reset() {
        session = nil
        builder = nil
        pendingFinish = nil
        startedAt = nil
        isActive = false
        isFinishing = false
        isStarting = false
        currentHeartRateBPM = nil
        averageHeartRateBPM = nil
        activeCaloriesKcal = nil
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .stopped else { return }
        Task { @MainActor in self.finalize(at: date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            Self.logger.error("workout session failed: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = error.localizedDescription
            self.pendingFinish?(nil)
            self.reset()
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor in self.updateStatistics(for: collectedTypes) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

final class WatchExtensionDelegate: NSObject, WKExtensionDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            WatchWorkoutManager.shared.start(configuration: workoutConfiguration)
        }
    }

    func handleActiveWorkoutRecovery() {
        Task { @MainActor in WatchWorkoutManager.shared.recoverActiveWorkout() }
    }
}
