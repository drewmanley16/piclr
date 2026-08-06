import SwiftUI

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showSavedToast = false
    @State private var restoreToast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identityCard
                    menuCard
                    if subscriptions.monetizationEnabled {
                        if subscriptions.isPro {
                            manageSubscriptionRow
                        }
                        restorePurchasesRow
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    HeaderCircleButton(systemImage: "xmark", accessibilityTitle: "Close") { dismiss() }
                }
            }
        }
        .toast(isPresented: $showSavedToast, message: "Profile saved")
        .toast(isPresented: .init(get: { restoreToast != nil }, set: { if !$0 { restoreToast = nil } }),
               message: restoreToast ?? "")
    }

    // MARK: Identity

    /// The user's own avatar + name stand in for a generic "Profile" menu row —
    /// the card shows who you are and taps through to edit it.
    private var identityCard: some View {
        NavigationLink {
            SettingsProfileView(onSaved: { showSavedToast = true })
        } label: {
            HStack(spacing: 14) {
                ProfileAvatar(profile: store.currentProfile, size: 56, unlinked: true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(store.currentProfile?.displayName ?? "Your profile")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if subscriptions.showsProStatus {
                            ProStatusBadge()
                        }
                    }
                    Text(identitySubtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile")
    }

    private var identitySubtitle: String {
        if let username = store.currentProfile?.username {
            return "@\(username) · Edit profile"
        }
        return "Edit name, photo, rating, side"
    }

    // MARK: Menu

    /// Navigation destinations grouped into one card of compact rows, matching
    /// the app's grouped-field idiom (hairline dividers inside a single card).
    private var menuCard: some View {
        VStack(spacing: 0) {
            menuRow(icon: "slider.horizontal.3", title: "Preferences",
                    subtitle: "Privacy, notifications, blocked accounts") {
                SettingsPreferencesView()
            }
            Divider().overlay(Theme.hairline)
            menuRow(icon: "person.crop.circle.badge.exclamationmark", title: "Account",
                    subtitle: "Log out, delete account") {
                SettingsAccountView(onDismissAll: { dismiss() })
            }
            Divider().overlay(Theme.hairline)
            menuRow(icon: "doc.text", title: "Legal",
                    subtitle: "Terms of Use, Privacy Policy") {
                SettingsLegalView()
            }
            Divider().overlay(Theme.hairline)
            contactRow
        }
        .padding(.horizontal, 16)
        .cardStyle(padding: 0)
    }

    /// Published contact address for reporting concerns, distinct from the
    /// in-feed Report flow (App Store Review Guideline 1.2).
    private var contactRow: some View {
        Link(destination: URL(string: Legal.supportMailtoURL)!) {
            HStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Contact & Support")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Legal.supportEmail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 12)
        }
        .accessibilityLabel("Contact and support, \(Legal.supportEmail)")
    }

    private func menuRow<Destination: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Manage subscription

    /// Opens the native "manage/cancel subscription" sheet for Pro subscribers.
    private var manageSubscriptionRow: some View {
        Button {
            Haptics.tap()
            Task { await subscriptions.manageSubscriptions() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage subscription")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Change plan, cancel, or view renewal date")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 8)
            }
            .cardStyle(padding: 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: Restore purchases

    /// Re-syncs App Store purchases (required subscription-app affordance for
    /// reinstalls / new devices). The paywall footer has the same action; this
    /// one is reachable without a paywall trigger. An action, not a destination,
    /// so no chevron — a spinner takes its place while working.
    private var restorePurchasesRow: some View {
        Button {
            Haptics.tap()
            Task {
                await subscriptions.restore()
                // On failure/no-op the store sets errorText; success leaves it nil.
                restoreToast = subscriptions.errorText ?? "Purchases restored"
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore purchases")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Already have Pro? Get it back on this device.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 8)

                if subscriptions.isWorking {
                    ProgressView().tint(Theme.accent)
                }
            }
            .cardStyle(padding: 12)
        }
        .buttonStyle(.plain)
        .disabled(subscriptions.isWorking)
    }

    // MARK: Footer

    /// Quiet brand mark + version pinned under the menu — puts the app version
    /// somewhere visible instead of buried in the Account subscreen.
    private var footer: some View {
        VStack(spacing: 3) {
            Text("piclr")
                .font(.headline.weight(.heavy))
                .tracking(-0.4)
                .foregroundStyle(Theme.textTertiary)
            Text("Version \(appVersion)")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
