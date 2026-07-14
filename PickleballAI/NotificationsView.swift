import SwiftUI

struct NotificationsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    private var isEmpty: Bool {
        store.incomingFollowRequests.isEmpty && store.incomingRepostRequests.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isEmpty {
                        emptyState
                    } else {
                        if !store.incomingFollowRequests.isEmpty {
                            section(title: "Follow Requests") {
                                ForEach(store.incomingFollowRequests) { FollowRequestRow(request: $0) }
                            }
                        }
                        if !store.incomingRepostRequests.isEmpty {
                            section(title: "Repost Requests") {
                                ForEach(store.incomingRepostRequests) { RepostRequestRow(request: $0) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await reload() }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            content()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
            Text("You're all caught up")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Follow and repost requests will show up here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func reload() async {
        guard let uid = store.currentProfile?.id else { return }
        await store.loadFollowState(userId: uid)
        await store.loadRepostRequests(userId: uid)
    }
}
