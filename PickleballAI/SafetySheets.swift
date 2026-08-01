import SwiftUI

// MARK: - Safety sheets

struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    let target: ReportTarget
    @State private var reason = ReportReason.harassment
    @State private var details = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { reason in
                            Text(reason.title).tag(reason)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Additional details") {
                    TextField("Optional details", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task {
                            if await store.submitReport(target: target, reason: reason, details: details) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(store.isBusy)
                }
            }
            .onAppear { store.errorMessage = nil }
        }
    }
}

struct BlockedAccountsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                if store.blockedAccounts.isEmpty {
                    Text("No blocked accounts.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(store.blockedAccounts) { account in
                        HStack(spacing: 12) {
                            // Deliberately non-navigable: you blocked them, so show
                            // the real avatar but don't route to their profile.
                            ProfileAvatar(
                                url: account.avatarURL,
                                initials: account.initials,
                                userId: account.blockedId,
                                unlinked: true
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.blockedDisplayName)
                                    .font(.body.weight(.semibold))
                                Text("@\(account.blockedUsername)")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button("Unblock") {
                                Task { await store.unblockUser(userId: account.id) }
                            }
                            .font(.subheadline.weight(.semibold))
                            .disabled(store.isBusy)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Blocked Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.loadBlockedAccounts() }
        }
    }
}

struct DeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This permanently deletes your profile, sessions, comments, follows, gear, and photos.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Permanently Delete Account", systemImage: "trash.fill")
                    }
                    .disabled(store.isBusy)
                }

                if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { store.errorMessage = nil }
            .confirmationDialog(
                "Delete your account permanently?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task {
                        if await store.deleteAccount() {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
