import SwiftUI

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSavedToast = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    SettingsMenuRow(icon: "person.crop.circle", title: "Profile", subtitle: "Name, photo, rating, side") {
                        SettingsProfileView(onSaved: { showSavedToast = true })
                    }
                    SettingsMenuRow(icon: "slider.horizontal.3", title: "Preferences", subtitle: "Notifications, blocked accounts") {
                        SettingsPreferencesView()
                    }
                    SettingsMenuRow(icon: "person.crop.circle.badge.exclamationmark", title: "Account", subtitle: "Version, log out, delete account") {
                        SettingsAccountView(onDismissAll: { dismiss() })
                    }
                    SettingsMenuRow(icon: "doc.text", title: "Legal", subtitle: "Terms of Use, Privacy Policy") {
                        SettingsLegalView()
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    HeaderCircleButton(systemImage: "xmark", accessibilityTitle: "Close") { dismiss() }
                }
            }
        }
        .toast(isPresented: $showSavedToast, message: "Profile saved")
    }
}

/// Root menu row for Settings: navigates to a category screen (Profile, Preferences, Account).
private struct SettingsMenuRow<Destination: View>: View {
    var icon: String
    var title: String
    var subtitle: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentSoft, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .cardStyle()
    }
}
