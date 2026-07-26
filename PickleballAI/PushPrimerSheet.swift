import SwiftUI

/// Soft pre-permission explainer shown once, before the hard iOS notification
/// prompt. Improves opt-in rate and avoids surprising a brand-new user with a
/// system dialog before they understand why the app wants it.
struct PushPrimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
                .frame(width: 96, height: 96)
                .background(Theme.accentSoft, in: Circle())

            VStack(spacing: 8) {
                Text("Stay in the loop")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Get notified when someone likes or comments on your sessions, follows you, or invites you to play.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Haptics.tap()
                    Task {
                        await store.enablePushNotifications()
                        dismiss()
                    }
                } label: {
                    Text("Enable Notifications")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                }

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Text("Not Now")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }
}
