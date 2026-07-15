import SwiftUI
import PhotosUI
import UIKit

// MARK: - Measures

struct MeasuresSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var heightFeet = ""
    @State private var heightInches = ""
    @State private var weightPounds = ""
    @State private var shoeSize = ""

    private var totalHeightInches: Double? {
        guard !heightFeet.isEmpty || !heightInches.isEmpty else { return nil }
        return (Double(heightFeet) ?? 0) * 12 + (Double(heightInches) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Height") {
                    HStack {
                        TextField("Feet", text: $heightFeet)
                            .keyboardType(.numberPad)
                        Text("ft").foregroundStyle(Theme.textSecondary)
                        TextField("Inches", text: $heightInches)
                            .keyboardType(.decimalPad)
                        Text("in").foregroundStyle(Theme.textSecondary)
                    }
                }

                Section("Body & Fit") {
                    HStack {
                        TextField("Weight", text: $weightPounds)
                            .keyboardType(.decimalPad)
                        Text("lb").foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        TextField("Shoe size", text: $shoeSize)
                            .keyboardType(.decimalPad)
                        Text("US").foregroundStyle(Theme.textSecondary)
                    }
                }

                Section {
                    Button {
                        Task {
                            let saved = await store.updateMeasures(
                                heightInches: totalHeightInches,
                                weightPounds: Double(weightPounds),
                                shoeSize: Double(shoeSize)
                            )
                            if saved { dismiss() }
                        }
                    } label: {
                        Text("Save Measures")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(store.isBusy)
                    .listRowBackground(Theme.accent)
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
            .listRowBackground(Theme.surface)
            .navigationTitle("Measures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                store.errorMessage = nil
                guard let profile = store.currentProfile else { return }
                if let total = profile.heightInches {
                    heightFeet = "\(Int(total) / 12)"
                    heightInches = String(format: "%g", total.truncatingRemainder(dividingBy: 12))
                }
                weightPounds = profile.weightPounds.map { String(format: "%g", $0) } ?? ""
                shoeSize = profile.shoeSize.map { String(format: "%g", $0) } ?? ""
            }
        }
    }
}

// MARK: - Statistics

struct StatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    private var totalMinutes: Int { store.mySessions.reduce(0) { $0 + $1.durationMinutes } }
    private var avgMinutes: Int { store.mySessions.isEmpty ? 0 : totalMinutes / store.mySessions.count }
    private var longest: Int { store.mySessions.map(\.durationMinutes).max() ?? 0 }
    private var stats: SessionStats { SessionStats(sessions: store.mySessions) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    let s = stats

                    if s.matches > 0 {
                        RecordHero(stats: s)
                    }

                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            StatPill(title: "Total Sessions", value: "\(store.mySessions.count)", systemImage: "figure.pickleball")
                            StatPill(title: "Total Hours", value: String(format: "%.1f", Double(totalMinutes) / 60), systemImage: "clock")
                        }
                        HStack(spacing: 12) {
                            StatPill(title: "Avg Session", value: "\(avgMinutes) min", systemImage: "timer")
                            StatPill(title: "Longest", value: "\(longest) min", systemImage: "flame")
                        }
                    }

                    if !s.opponents.isEmpty {
                        RecordSection(title: "Head-to-Head", caption: "vs.", records: s.opponents)
                    }
                    if !s.partners.isEmpty {
                        RecordSection(title: "Partners", caption: "with", records: s.partners)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct RecordHero: View {
    let stats: SessionStats

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(stats.wins)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text("–")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(stats.losses)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("MATCH RECORD")
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                HeroStat(value: "\(stats.winRate)%", label: "Win rate")
                Divider().frame(height: 28).overlay(Theme.hairline)
                HeroStat(value: "\(stats.matches)", label: "Matches")
                Divider().frame(height: 28).overlay(Theme.hairline)
                HeroStat(value: stats.streakLabel, label: "Streak")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }
}

private struct HeroStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecordSection: View {
    let title: String
    let caption: String
    let records: [PlayerRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Divider().overlay(Theme.hairline).padding(.leading, 56)
                    }
                    PlayerRecordRow(record: record)
                }
            }
            .cardStyle(padding: 0)
        }
    }
}

private struct PlayerRecordRow: View {
    let record: PlayerRecord

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatar(url: nil, initials: record.avatarInitials)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let handle = record.handle {
                    Text(handle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.recordLine)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(record.wins >= record.losses ? Theme.accent : Theme.textPrimary)
                Text("\(record.winRate)%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Gear

struct GearSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.gear.isEmpty {
                        Text("Add your paddles, shoes, and bag to build your locker.")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .padding(.top, 8)
                    } else {
                        ForEach(store.gear) { GearRow(item: $0) }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("My Gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddGearSheet().presentationDetents([.medium]) }
        }
    }
}

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
                Text(item.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Menu {
                Button(role: .destructive) {
                    Task { await store.deleteGear(item) }
                } label: { Label("Remove", systemImage: "trash") }
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
        if let brand = item.brand, !brand.isEmpty { return "\(brand) · \(item.category)" }
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
                        ForEach(GearCategory.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Name (e.g. Perseus 16mm)", text: $name)
                    TextField("Brand (optional)", text: $brand)
                }
                Section {
                    Button {
                        Task {
                            let saved = await store.addGear(category: category.rawValue, name: name, brand: brand)
                            if saved { dismiss() }
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
            .listRowBackground(Theme.surface)
            .navigationTitle("Add Gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { store.errorMessage = nil }
        }
    }
}

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

// MARK: - Settings: Profile

struct SettingsProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    var onSaved: () -> Void = {}
    @State private var displayName = ""
    @State private var homeCourt = ""
    @State private var rating = ""
    @State private var preferredSide = "Left"
    @State private var birthdaySet = false
    @State private var birthdayDate = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    private let sides = ["Left", "Right", "Both"]

    private static let birthdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                photoHeader

                accountCard

                playerDetailsSection

                birthdayCard

                saveButton

                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadProfile() }
        .onChange(of: selectedPhoto) { _, item in
            Task {
                selectedPhotoData = try? await item?.loadTransferable(type: Data.self)
            }
        }
    }

    // MARK: - Sections

    private var photoHeader: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    profilePhoto
                    Image(systemName: "pencil")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 3))
                }
            }
            .buttonStyle(.plain)

            Text(store.currentProfile.map { "@\($0.username)" } ?? "—")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldRow(label: "NAME") {
                TextField("Display name", text: $displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Divider().overlay(Theme.hairline)
            fieldRow(label: "HOME COURT") {
                TextField("Add your home court", text: $homeCourt)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .cardStyle()
    }

    private var playerDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Player Details")

            VStack(spacing: 6) {
                Text("RATING (DUPR)")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                TextField("0.00", text: $rating)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(Theme.scoreboard(44))
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .cardStyle(padding: 20)

            SideSelector(sides: sides, selection: $preferredSide)
        }
    }

    private var birthdayCard: some View {
        VStack(alignment: .leading, spacing: birthdaySet ? 14 : 0) {
            Toggle("Add birthday", isOn: $birthdaySet.animation())
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
            if birthdaySet {
                DatePicker("Birthday", selection: $birthdayDate, in: ...Date(), displayedComponents: .date)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .cardStyle()
    }

    private var saveButton: some View {
        Button {
            Task { await saveProfile() }
        } label: {
            Text(store.isBusy ? "Saving..." : "Save Profile")
                .font(.headline)
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .background(Theme.accent, in: Capsule())
        .disabled(displayName.isEmpty || store.isBusy)
        .opacity(displayName.isEmpty || store.isBusy ? 0.5 : 1)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    @ViewBuilder
    private var profilePhoto: some View {
        if let selectedPhotoData, let image = UIImage(data: selectedPhotoData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        } else {
            ProfileAvatar(profile: store.currentProfile, size: 96)
        }
    }

    private func loadProfile() {
        store.errorMessage = nil
        guard let profile = store.currentProfile else { return }
        displayName = profile.displayName
        homeCourt = profile.homeCourt ?? ""
        rating = profile.rating.map { String(format: "%.2f", $0) } ?? ""
        preferredSide = profile.preferredSide ?? "Left"
        if let bday = profile.birthday, let date = Self.birthdayFormatter.date(from: bday) {
            birthdayDate = date
            birthdaySet = true
        } else {
            birthdaySet = false
        }
    }

    private func saveProfile() async {
        let photoData = selectedPhotoData
        // The two writes touch different columns, so run them concurrently to
        // overlap their network round trips.
        async let profileSaved = store.updateProfile(
            displayName: displayName,
            homeCourt: homeCourt,
            rating: Double(rating),
            preferredSide: preferredSide,
            birthday: birthdaySet ? Self.birthdayFormatter.string(from: birthdayDate) : nil
        )
        async let photoSaved: Bool = {
            guard let photoData else { return true }
            return await store.uploadProfilePhoto(photoData)
        }()

        guard await profileSaved, await photoSaved else { return }
        selectedPhotoData = nil
        selectedPhoto = nil
        onSaved()
        dismiss()
    }
}

// MARK: - Settings: Preferences

struct SettingsPreferencesView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("notificationsEnabled") private var notifications = true
    @State private var showBlockedAccounts = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
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
    }
}

// MARK: - Settings: Account

struct SettingsAccountView: View {
    @EnvironmentObject private var store: AppStore
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

// MARK: - Safety sheets

struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

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
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                if store.blockedAccounts.isEmpty {
                    Text("No blocked accounts.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(store.blockedAccounts) { account in
                        HStack(spacing: 12) {
                            ProfileAvatar(url: nil, initials: account.initials)
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
    @EnvironmentObject private var store: AppStore

    @State private var phone = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var confirmDelete = false

    private var codeDigits: String { String(code.filter(\.isNumber).prefix(6)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This permanently deletes your profile, sessions, comments, follows, gear, and photos.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Section("Verify your account") {
                    if !phone.isEmpty {
                        LabeledContent("Phone", value: maskedPhone)
                    }
                    if codeSent {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    } else {
                        Button {
                            Task {
                                if await store.sendPhoneOTP(phone: phone) {
                                    codeSent = true
                                }
                            }
                        } label: {
                            Label("Send Verification Code", systemImage: "message.fill")
                        }
                        .disabled(phone.isEmpty || store.isBusy)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Permanently Delete Account", systemImage: "trash.fill")
                    }
                    .disabled(codeDigits.count != 6 || store.isBusy)
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
            .task { phone = await store.accountPhone() ?? "" }
            .onAppear { store.errorMessage = nil }
            .confirmationDialog(
                "Delete your account permanently?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task {
                        if await store.deleteAccount(phone: phone, token: codeDigits) {
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

    private var maskedPhone: String {
        guard phone.count > 4 else { return phone }
        return String(repeating: "•", count: max(0, phone.count - 4)) + phone.suffix(4)
    }
}
