import Foundation
import WatchConnectivity
import os

/// Phone side of the watch link. Mirrors `PushService` / `LiveActivityManager`:
/// a `@MainActor` singleton that owns the `WCSession` and hands decoded
/// `WatchSyncMessage`s to whoever wires up `onMessage` (the `AppStore`).
///
/// W1 scope: activate the session and surface inbound messages. Reflecting the
/// received score into `AppStore.activeDraft` / the Live Activity, and building a
/// match `DraftActivity` on `endGame`, lands in W2–W3 — the transport and
/// contract are proven here first.
@MainActor
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    nonisolated private static let logger = Logger(subsystem: "com.pickleball.ai", category: "WC")

    /// Invoked on the main actor for every inbound message from the watch.
    var onMessage: ((WatchSyncMessage) -> Void)?
    var onConnectionChange: ((_ activated: Bool, _ reachable: Bool) -> Void)?

    @Published private(set) var isActivated = false
    @Published private(set) var isReachable = false

    private var session: WCSession { .default }
    private var pendingCommands: [WatchCommand] = []

    /// Idempotent: safe to call on every sign-in / launch.
    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        if session.activationState == .activated {
            connectionDidChange()
            flushPendingCommands()
        } else {
            session.activate()
        }
    }

    // MARK: Outbound (phone edits mirror back to the watch — used from W2 on)

    func sendScore(_ score: LiveMatchScore) {
        guard WCSession.isSupported(), session.activationState == .activated else {
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

    func sendCommand(_ command: WatchCommand) {
        guard WCSession.isSupported() else { return }
        guard session.activationState == .activated else {
            pendingCommands.append(command)
            activate()
            return
        }
        transmit(command)
    }

    private func transmit(_ command: WatchCommand) {
        let payload = WatchSyncMessage.command(command).payload
        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                Self.logger.debug("sendMessage(command) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushPendingCommands() {
        guard session.activationState == .activated, !pendingCommands.isEmpty else { return }
        let commands = pendingCommands
        pendingCommands.removeAll()
        commands.forEach(transmit)
    }

    private func connectionDidChange() {
        let activated = session.activationState == .activated
        let reachable = activated && session.isReachable
        let changed = activated != isActivated || reachable != isReachable
        isActivated = activated
        isReachable = reachable
        if changed { onConnectionChange?(activated, reachable) }
    }

    // MARK: Inbound

    private func deliver(_ payload: [String: Any]) {
        guard let message = WatchSyncMessage(payload: payload) else { return }
        Task { @MainActor in
            Self.logger.debug("received \(String(describing: message), privacy: .public)")
            self.onMessage?(message)
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            Self.logger.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor in
            self.connectionDidChange()
            self.flushPendingCommands()
        }
    }

    // The phone must re-activate after switching between paired watches.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.connectionDidChange() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.deliver(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.deliver(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.deliver(userInfo) }
    }
}
