import Foundation
import WatchConnectivity
import os

/// Watch side of the WatchConnectivity link. Mirrors the app's singleton-manager
/// pattern (`PushService` / `LiveActivityManager`): activate a `WCSession`, own
/// the delegate, and hand decoded `WatchSyncMessage`s up to `WatchGameStore`.
///
/// Transport policy (matches the phone side):
///   • score snapshots → `updateApplicationContext` (coalesced, background) plus
///     `sendMessage` when reachable for an instant mirror.
///   • commands        → `transferUserInfo` (guaranteed-delivery FIFO queue).
final class WatchConnectivityClient: NSObject {
    static let shared = WatchConnectivityClient()

    private static let logger = Logger(subsystem: "com.pickleball.ai.watchapp", category: "WC")

    /// Called on the main queue with every inbound message (score or command).
    var onMessage: ((WatchSyncMessage) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?

    private var session: WCSession { .default }
    private var pendingCommands: [WatchCommand] = []

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        if session.activationState == .activated {
            flushPendingCommands()
            onReachabilityChange?(session.isReachable)
        } else {
            session.activate()
        }
    }

    // MARK: Outbound

    /// Send the latest full snapshot. Coalesced background delivery via
    /// application context, plus an instant mirror when the phone is reachable.
    func sendScore(_ score: LiveMatchScore) {
        guard session.activationState == .activated else {
            activate()
            return
        }
        let payload = WatchSyncMessage.score(score).payload
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                Self.logger.debug("sendMessage(score) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Send a lifecycle command over the guaranteed-delivery queue so it lands
    /// even if the phone is briefly unreachable (in a bag courtside).
    func sendCommand(_ command: WatchCommand, immediately: Bool = false) {
        guard session.activationState == .activated else {
            pendingCommands.append(command)
            activate()
            return
        }
        transmit(command, immediately: immediately)
    }

    private func transmit(_ command: WatchCommand, immediately: Bool) {
        let payload = WatchSyncMessage.command(command).payload
        session.transferUserInfo(payload)
        if immediately, session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                Self.logger.debug("sendMessage(command) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushPendingCommands() {
        guard session.activationState == .activated, !pendingCommands.isEmpty else { return }
        let commands = pendingCommands
        pendingCommands.removeAll()
        commands.forEach { transmit($0, immediately: true) }
    }

    /// Streams a live sensor snapshot only while the iPhone app is reachable.
    /// Unlike lifecycle commands, samples are not queued for later delivery.
    func sendLiveWorkoutMetrics(_ metrics: LiveWorkoutMetrics) {
        guard session.activationState == .activated, session.isReachable else { return }
        let payload = WatchSyncMessage.command(.liveWorkoutMetrics(metrics)).payload
        session.sendMessage(payload, replyHandler: nil) { error in
            Self.logger.debug("sendMessage(live metrics) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Inbound plumbing

    private func deliver(_ payload: [String: Any]) {
        guard let message = WatchSyncMessage(payload: payload) else { return }
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            Self.logger.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingCommands()
            self?.onReachabilityChange?(state == .activated && session.isReachable)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.onReachabilityChange?(session.isReachable)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }
}
