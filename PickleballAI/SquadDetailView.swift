import SwiftUI

/// One squad: roster, squad-scoped leaderboard, invite (code + direct), and
/// owner/member management. Pushed from `SquadsListSheet`.
struct SquadDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    let squad: Squad

    @State private var loaded = false
    @State private var period: LeaderboardPeriod = .all
    @State private var showInviteFollower = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var removeTarget: SquadMember?

    private var isOwner: Bool { squad.ownerId == store.currentProfile?.id }
    private var ranked: [SquadLeaderboardEntry] { store.squadLeaderboard.filter { $0.matches > 0 } }
    private var unranked: [SquadLeaderboardEntry] { store.squadLeaderboard.filter { $0.matches == 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                inviteSection
                rosterSection
                leaderboardSection
                footerActions
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(squad.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwner {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename Squad") {
                            renameText = squad.name
                            showRename = true
                        }
                        Button("Delete Squad", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Squad actions")
                }
            }
        }
        .task {
            store.activeSquad = squad
            await store.loadSquadDetail(squad.id, period: period)
            loaded = true
        }
        .refreshable { await store.loadSquadDetail(squad.id, period: period) }
        .sheet(isPresented: $showInviteFollower) { InviteFollowerSheet(squad: squad) }
        .alert("Rename Squad", isPresented: $showRename) {
            TextField("Squad name", text: $renameText)
            Button("Save") {
                Task { await store.renameSquad(squad.id, name: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Leave this squad?",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task {
                    await store.leaveSquad(squad.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this squad for everyone?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Squad", role: .destructive) {
                Task {
                    await store.deleteSquad(squad.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the squad and its roster for every member. This can't be undone.")
        }
        .confirmationDialog(
            "Remove \(removeTarget?.profile?.displayName ?? "this member") from the squad?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let userId = removeTarget?.userId {
                    Task { await store.removeSquadMember(squadId: squad.id, userId: userId) }
                }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.3.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Theme.surfaceElevated, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(squad.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(store.squadRoster.count) member\(store.squadRoster.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: Invite

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                InviteShareLink(
                    message: "Join my squad \u{201C}\(squad.name)\u{201D} on piclr \u{2014} code \(squad.joinCode)\n\(AppLinks.squadJoin(squad.joinCode).absoluteString)",
                    subject: "Join my squad on piclr",
                    source: "squad_invite"
                ) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                }
                if isOwner {
                    Button {
                        Haptics.tap()
                        showInviteFollower = true
                    } label: {
                        Label("Invite a Follower", systemImage: "person.crop.circle.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Code: \(squad.joinCode)")
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Roster

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROSTER")
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)
            if !loaded && store.squadRoster.isEmpty {
                SkeletonList(rows: 3)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.squadRoster.enumerated()), id: \.element.id) { index, member in
                        if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                        rosterRow(member)
                    }
                }
                .cardStyle(padding: 8)
            }
        }
    }

    private func rosterRow(_ member: SquadMember) -> some View {
        IdentityRow(
            avatarURL: member.profile?.avatarURL,
            initials: member.profile?.avatarInitials ?? "?",
            name: member.profile?.displayName ?? "Unknown",
            detail: member.isOwner ? "Owner" : (member.profile.map { "@\($0.username)" }),
            userId: member.userId,
            isPro: member.profile?.isPro ?? false
        ) {
            if isOwner && !member.isOwner {
                Button {
                    removeTarget = member
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Theme.loss)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    // MARK: Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LEADERBOARD")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                periodPicker
            }
            if ranked.isEmpty && unranked.isEmpty {
                Text("Log matches to populate this squad's leaderboard.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                if !ranked.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(ranked.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                            LeaderboardRow(rank: index + 1, entry: entry, isYou: isYou(entry))
                        }
                    }
                    .cardStyle(padding: 8)
                }
                if !unranked.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(unranked.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                            LeaderboardRow(rank: nil, entry: entry, isYou: isYou(entry))
                        }
                    }
                    .cardStyle(padding: 8)
                }
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 6) {
            ForEach(LeaderboardPeriod.allCases) { option in
                let locked = option.isPro && !subscriptions.isPro
                Button {
                    Haptics.tap()
                    if locked {
                        subscriptions.presentPaywall(.leaderboard)
                    } else {
                        period = option
                        Task { await store.loadSquadLeaderboard(squadId: squad.id, period: period) }
                    }
                } label: {
                    Text(option.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(period == option ? Theme.background : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(period == option ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isYou(_ entry: SquadLeaderboardEntry) -> Bool {
        entry.userId == store.currentProfile?.id
    }

    // MARK: Footer

    private var footerActions: some View {
        Group {
            if isOwner {
                Button("Delete Squad", role: .destructive) { confirmDelete = true }
            } else {
                Button("Leave Squad", role: .destructive) { confirmLeave = true }
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

/// Owner-only picker to invite an existing follower directly into the squad.
private struct InviteFollowerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let squad: Squad
    @State private var loaded = false

    private var candidates: [FollowListEntry] {
        let memberIds = Set(store.squadRoster.map(\.userId))
        return store.following.filter { !memberIds.contains($0.userId) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    SkeletonList(rows: 4)
                } else if candidates.isEmpty {
                    VStack(spacing: 10) {
                        Text("No one left to invite")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Everyone you follow is already in this squad, or share the join code instead.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)
                    .padding(.horizontal, 24)
                } else {
                    List(candidates) { entry in
                        IdentityRow(
                            avatarURL: entry.profile?.avatarURL,
                            initials: entry.profile?.avatarInitials ?? "?",
                            name: entry.profile?.displayName ?? "Unknown",
                            detail: entry.profile.map { "@\($0.username)" },
                            userId: entry.userId
                        ) {
                            Button("Invite") {
                                Haptics.tap()
                                Task { await store.inviteFollowerToSquad(squadId: squad.id, userId: entry.userId) }
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .tint(Theme.accent)
                        }
                        .listRowBackground(Theme.background)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Invite a Follower")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await store.loadFollowLists()
                loaded = true
            }
        }
    }
}
