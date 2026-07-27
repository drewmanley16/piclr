import SwiftUI

/// "My Squads": every squad the signed-in user belongs to, plus entry points
/// to create a new one or join an existing one by code. Reachable from the
/// Profile tab dashboard.
struct SquadsListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var loaded = false
    @State private var showCreate = false
    @State private var showJoin = false

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    actions
                    if !loaded && store.mySquads.isEmpty {
                        SkeletonList(rows: 3)
                    } else if store.mySquads.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.mySquads.enumerated()), id: \.element.id) { index, squad in
                                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                                NavigationLink(value: squad) {
                                    SquadRow(squad: squad)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .cardStyle(padding: 8)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Squads")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Squad.self) { squad in
                SquadDetailView(squad: squad)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showCreate) { CreateSquadSheet() }
            .sheet(isPresented: $showJoin) { JoinSquadSheet() }
            .task {
                await store.loadMySquads()
                loaded = true
            }
            .refreshable { await store.loadMySquads() }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            actionButton(title: "Create Squad", systemImage: "plus.circle.fill") {
                Haptics.tap()
                showCreate = true
            }
            actionButton(title: "Join with Code", systemImage: "qrcode") {
                Haptics.tap()
                showJoin = true
            }
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("No squads yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Start a squad and invite your regulars, or join one with a code.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private struct SquadRow: View {
    let squad: Squad

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(squad.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("Code \(squad.joinCode)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
