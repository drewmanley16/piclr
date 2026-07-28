import SwiftUI

// MARK: - Invite analytics

/// The single funnel event powering the referral loop. `source` distinguishes
/// where the share was triggered so the growth funnel can compare surfaces.
/// Values: "onboarding", "find_friends", "guest_row". Routes through the shared
/// `Analytics` taxonomy so the event name lives in exactly one place.
enum InviteAnalytics {
    static func linkShared(source: String) {
        Analytics.capture(.inviteLinkShared, [Analytics.Property.source: source])
    }
}

// MARK: - Personalized invite link + deep-link handling

extension AppStore {
    /// The signed-in user's personalized invite link (a universal link to their
    /// own profile). Falls back to the App Store listing before a session is
    /// known, so a share always produces a working link.
    var myProfileLink: URL {
        if let id = currentProfile?.id ?? supabase.auth.currentSession?.user.id {
            return AppLinks.profile(id)
        }
        return URL(string: AppLinks.appStore)!
    }

    /// Share copy for a general "add me" invite, personalized with the handle
    /// when we have one.
    var inviteShareMessage: String {
        let link = myProfileLink.absoluteString
        if let username = currentProfile?.username,
           !username.isEmpty, !username.hasPrefix("player_") {
            return "Add me on piclr: @\(username)\n\n\(link)"
        }
        return "Add me on piclr. Log every match with your crew.\n\n\(link)"
    }

    /// Share copy naming a specific guest we just played, e.g.
    /// "Dave, I logged our match on piclr, come see it: <link>".
    func guestInviteMessage(for name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return "\(first), I logged our match on piclr, come see it: \(myProfileLink.absoluteString)"
    }

    /// Routes an incoming universal/custom link. Expects `/u/{userId}` and opens
    /// that profile through the existing deep-link system (the profile sheet with
    /// a Follow button), or `pickleballai://live-session` from the Live Activity.
    /// Returns whether the link was recognized.
    @discardableResult
    func handleInviteURL(_ url: URL) -> Bool {
        // Live Activity tap: resume the in-progress session. Handled outside
        // `pendingDeepLink` because the live session is a fullScreenCover owned
        // by WorkoutView, not one of the deep-link sheets. On a cold launch the
        // URL lands before `loadSignedInData` restores the persisted draft, so
        // only a signed-in-and-draftless app can say for sure there's nothing to
        // open; that stale case is also swept in `loadSignedInData`.
        if url.scheme == SessionActivityAttributes.liveSessionURL.scheme,
           url.host == SessionActivityAttributes.liveSessionURL.host {
            if activeDraft != nil || authState != .signedIn {
                openLiveSessionRequest = UUID()
            }
            return true
        }
        // Path-based routes, recognized regardless of scheme: the universal
        // link https://webHost/{route}/{value}, or the equivalent custom
        // scheme pickleballai://{route}/{value}. A custom scheme's first
        // segment lands in `host`, not `pathComponents` (unlike https, where
        // `host` is webHost and doesn't participate in routing), so route
        // parts are normalized to start with `host` only for the custom
        // scheme. /u/{userId} and /squad/{code}. See AppLinks.profile / .squadJoin.
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "pickleballai", let host = url.host, !host.isEmpty {
            parts = [host] + parts
        }
        guard let first = parts.first?.lowercased() else { return false }
        switch first {
        case "u":
            guard parts.count >= 2, let userId = UUID(uuidString: parts[1]) else { return false }
            pendingDeepLink = .profile(userId)
            return true
        case "squad":
            guard parts.count >= 2, !parts[1].isEmpty else { return false }
            pendingDeepLink = .squadInvite(code: parts[1])
            return true
        default:
            return false
        }
    }
}

// MARK: - Share components

/// A ShareLink that shares a ready-made invite message and fires the
/// `invite_link_shared` funnel event (plus a tap haptic) when opened. Sharing a
/// plain string keeps the copy — and its embedded link — exactly as written.
struct InviteShareLink<Label: View>: View {
    let message: String
    var subject: String?
    let source: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        ShareLink(item: message, subject: subject.map { Text($0) }) {
            label()
        }
        .simultaneousGesture(TapGesture().onEnded {
            Haptics.tap()
            InviteAnalytics.linkShared(source: source)
        })
    }
}

/// Compact "Invite" pill shown next to a guest player (a real person who played
/// a real match but isn't on the app yet). Shares the sharer's personalized link
/// with a message naming the guest.
struct GuestInviteButton: View {
    @EnvironmentObject private var store: AppStore
    let guestName: String
    var source = "guest_row"

    var body: some View {
        InviteShareLink(
            message: store.guestInviteMessage(for: guestName),
            subject: "Come see our match on piclr",
            source: source
        ) {
            Label("Invite", systemImage: "person.crop.circle.badge.plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.accent.opacity(0.14), in: Capsule())
        }
        .accessibilityLabel("Invite \(guestName)")
    }
}
