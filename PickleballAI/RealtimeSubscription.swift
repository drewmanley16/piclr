import Foundation
import Supabase

// MARK: - Realtime subscription lifecycle

/// Owns one realtime channel and the listener task(s) draining its change
/// streams, so every subscription gets a matching teardown for free instead of
/// each site hand-rolling channel/task ivar pairs.
///
/// `configure` runs synchronously with the fresh channel so callers can build
/// their `postgresChange` streams *before* anything subscribes (supabase-swift
/// registers bindings at subscribe time — a stream created afterwards would
/// never receive events). Each returned closure becomes an owned Task; by
/// convention the first one calls `channel.subscribe()`, matching how a channel
/// with multiple streams was driven before this wrapper existed.
@MainActor
final class RealtimeSubscription {
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []

    /// Tears down any previous subscription, then creates the named channel and
    /// starts one Task per closure returned from `configure`.
    func start(
        channelName: String,
        configure: (RealtimeChannelV2) -> [@MainActor () async -> Void]
    ) {
        stop()
        let channel = supabase.channel(channelName)
        self.channel = channel
        tasks = configure(channel).map { operation in
            Task { await operation() }
        }
    }

    /// Cancels the listener task(s) and unsubscribes the channel.
    func stop() {
        for task in tasks { task.cancel() }
        tasks = []
        if let channel {
            self.channel = nil
            Task { await channel.unsubscribe() }
        }
    }

    deinit {
        // stop() is MainActor-bound; from deinit we can only cancel the tasks.
        // In practice AppStore owns these for its whole lifetime and calls
        // stop() explicitly on sign-out, so this is just a safety net.
        for task in tasks { task.cancel() }
    }
}
