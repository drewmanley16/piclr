import SwiftUI

// MARK: - Settings: Preferences

struct SettingsPreferencesView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("notificationsEnabled") private var notifications = true
    @State private var showBlockedAccounts = false
    @State private var privateAccount = false
    @State private var isSavingPrivacy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Toggle(isOn: $privateAccount) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Private account", systemImage: "lock")
                            .foregroundStyle(Theme.textPrimary)
                        Text("Only accepted followers can see your sessions")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.accent)
                .disabled(isSavingPrivacy)
                .onChange(of: privateAccount) { _, enabled in
                    Haptics.tap()
                    isSavingPrivacy = true
                    Task {
                        let succeeded = await store.updatePrivacy(isPrivate: enabled)
                        // Serialized by `isSavingPrivacy` disabling the toggle
                        // mid-flight, so this can't race a second in-flight write.
                        if !succeeded { privateAccount = !enabled }
                        isSavingPrivacy = false
                    }
                }

                Divider().overlay(Theme.hairline)

                Toggle(isOn: $notifications) {
                    Label("Push notifications", systemImage: "bell")
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .onChange(of: notifications) { _, enabled in
                    Task {
                        if enabled {
                            let granted = await store.enablePushNotifications()
                            // If the user denied at the system level, reflect that.
                            if !granted { notifications = false }
                        } else {
                            await store.removeDeviceToken()
                        }
                    }
                }

                Divider().overlay(Theme.hairline)

                Button {
                    showBlockedAccounts = true
                } label: {
                    HStack {
                        Label("Blocked Accounts", systemImage: "person.crop.circle.badge.xmark")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .cardStyle()
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBlockedAccounts) {
            BlockedAccountsView()
        }
        .onAppear {
            privateAccount = store.currentProfile?.isPrivate ?? false
        }
    }
}

// MARK: - Settings: Account

struct SettingsAccountView: View {
    @Environment(AppStore.self) private var store
    var onDismissAll: () -> Void

    @State private var showDeleteAccount = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Text("Version").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(appVersion).foregroundStyle(Theme.textSecondary)
                }
                .cardStyle()

                VStack(spacing: 14) {
                    Button(role: .destructive) {
                        Task { await store.signOut(); onDismissAll() }
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().overlay(Theme.hairline)
                    Button(role: .destructive) {
                        showDeleteAccount = true
                    } label: {
                        Label("Delete Account", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .cardStyle()
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountSheet()
        }
    }
}
