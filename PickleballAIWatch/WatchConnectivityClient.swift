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

    private var session: WCSession { .default }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: Outbound

    /// Send the latest full snapshot. Coalesced background delivery via
    /// application context, plus an instant mirror when the phone is reachable.
    func sendScore(_ score: LiveMatchScore) {
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
    func sendCommand(_ command: WatchCommand) {
        session.transferUserInfo(WatchSyncMessage.command(command).payload)
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
