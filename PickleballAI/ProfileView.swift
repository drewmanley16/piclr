import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    @State private var showAddGear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                profileHeader
                weeklyActivity
                gearSection
                measures
                postings
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .top) {
            AppHeader(title: "Profile") {
                HeaderCircleButton(systemImage: "gearshape", accessibilityTitle: "Settings") {
                    showSettings = true
                }
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAddGear) {
            AddGearSheet()
                .presentationDetents([.medium])
        }
    }

    private var gearSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Gear")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    showAddGear = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            if store.gear.isEmpty {
                Text("Add your paddles, shoes, and bag to build your locker.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(store.gear) { item in
                    GearRow(item: item)
                }
            }
        }
    }

    private var profile: Profile? { store.currentProfile }

    private var totalHours: String {
        let minutes = store.mySessions.reduce(0) { $0 + $1.durationMinutes }
        return String(format: "%.1f", Double(minutes) / 60)
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text(profile?.initials ?? "PB")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 72, height: 72)
                    .background(Theme.surfaceElevated, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile?.displayName ?? "—")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(handleLine)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: 0) {
                FollowStat(value: "\(store.followerCount)", label: "Followers")
                FollowStat(value: "\(store.followingCount)", label: "Following")
                FollowStat(value: "\(store.mySessions.count)", label: "Posts")
            }
        }
        .cardStyle()
    }

    private var handleLine: String {
        guard let profile else { return "@—" }
        if let court = profile.homeCourt, !court.isEmpty {
            return "@\(profile.username) · \(court)"
        }
        return "@\(profile.username)"
    }

    private var weeklyActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 12) {
                StatPill(title: "Sessions", value: "\(store.mySessions.count)", systemImage: "figure.pickleball")
                StatPill(title: "Hours", value: totalHours, systemImage: "clock")
                StatPill(title: "Following", value: "\(store.followingCount)", systemImage: "person.2")
            }
        }
    }

    private var measures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measures")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 0) {
                MeasureRow(label: "Rating", value: profile?.rating.map { "\(String(format: "%.2f", $0)) DUPR" } ?? "—")
                rowDivider
                MeasureRow(label: "Paddle", value: profile?.paddle ?? "—")
                rowDivider
                MeasureRow(label: "Preferred side", value: profile?.preferredSide ?? "—")
            }
            .padding(.horizontal, 16)
            .cardStyle(padding: 0)
        }
    }

    private var postings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Posts")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            if store.mySessions.isEmpty {
                Text("Nothing posted yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(store.mySessions) { session in
                    PostingRow(session: session)
                }
            }
        }
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline)
    }
}

struct FollowStat: View {
    var value: String
    var label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MeasureRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minHeight: 48)
    }
}

struct PostingRow: View {
    var session: FeedSession

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.pickleball")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(session.durationMinutes) min · \(session.location ?? "—")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.date.relativeLabel)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .cardStyle()
    }
}

// MARK: - Gear

struct GearRow: View {
    @EnvironmentObject private var store: AppStore
    var item: GearItem

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.categoryIcon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Menu {
                Button(role: .destructive) {
                    Task { await store.deleteGear(item) }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
            }
        }
        .cardStyle()
    }

    private var subtitle: String {
        if let brand = item.brand, !brand.isEmpty {
            return "\(brand) · \(item.category)"
        }
        return item.category
    }
}

struct AddGearSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var category = GearCategory.paddle
    @State private var name = ""
    @State private var brand = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Gear") {
                    Picker("Category", selection: $category) {
                        ForEach(GearCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    TextField("Name (e.g. Perseus 16mm)", text: $name)
                    TextField("Brand (optional)", text: $brand)
                }

                Section {
                    Button {
                        Task {
                            await store.addGear(category: category.rawValue, name: name, brand: brand)
                            dismiss()
                        }
                    } label: {
                        Label("Add Gear", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(name.isEmpty || store.isBusy)
                    .listRowBackground(Theme.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle("Add Gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsRow(label: "Account", systemImage: "person")
                    SettingsRow(label: "Notifications", systemImage: "bell")
                    SettingsRow(label: "Privacy", systemImage: "lock")
                }

                Section {
                    SettingsRow(label: "Help & Support", systemImage: "questionmark.circle")
                    SettingsRow(label: "About", systemImage: "info.circle")
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await store.signOut()
                            dismiss()
                        }
                    } label: {
                        Text("Log out")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingsRow: View {
    var label: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(label)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(minHeight: 44)
    }
}
