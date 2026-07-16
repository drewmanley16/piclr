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

    /// Gear grouped into sections by category, in the category enum's order, so
    /// the locker reads as an organized set of shelves rather than a flat list.
    private var sections: [(category: GearCategory, items: [GearItem])] {
        GearCategory.allCases.compactMap { category in
            let items = store.gear.filter { $0.category == category.rawValue }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.gear.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sections, id: \.category) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.category.rawValue.uppercased())
                                    .font(.caption.weight(.bold))
                                    .tracking(0.8)
                                    .foregroundStyle(Theme.textTertiary)
                                ForEach(section.items) { GearRow(item: $0) }
                            }
                        }
                    }
                    .padding(16)
                }
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
            .sheet(isPresented: $showAdd) { AddGearSheet().presentationDetents([.large]) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bag.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Build your locker")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Add your paddles, balls, shoes, and more to keep your setup in one place.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button { showAdd = true } label: {
                Label("Add gear", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .padding(.top, 60)
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

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CATEGORY")
                            .font(.caption.weight(.bold)).tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(GearCategory.allCases) { cat in
                                CategoryChip(category: cat, isSelected: category == cat) {
                                    Haptics.tap()
                                    withAnimation(.snappy(duration: 0.18)) { category = cat }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("DETAILS")
                            .font(.caption.weight(.bold)).tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                        AuthField(placeholder: category.namePlaceholder, text: $name)
                        AuthField(placeholder: "Brand (optional)", text: $brand)
                    }

                    Button {
                        Task {
                            let saved = await store.addGear(category: category.rawValue, name: name, brand: brand)
                            if saved { Haptics.success(); dismiss() }
                        }
                    } label: {
                        Text(store.isBusy ? "Adding…" : "Add to locker")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(name.isEmpty || store.isBusy)
                    .opacity(name.isEmpty || store.isBusy ? 0.5 : 1)

                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Add Gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { store.errorMessage = nil }
        }
    }
}

/// Selectable category tile for the Add-Gear grid: icon over label, lit in accent
/// when chosen.
private struct CategoryChip: View {
    let category: GearCategory
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Theme.background : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(isSelected ? Theme.accent : Theme.accentSoft, in: Circle())
                Text(category.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
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

// MARK: - Settings: Profile

struct SettingsProfileView: View {
    private enum NameField: Hashable {
        case firstName
        case lastName
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    var onSaved: () -> Void = {}
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var touchedNameFields: Set<NameField> = []
    @FocusState private var focusedNameField: NameField?
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
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadProfile() }
        .onChange(of: selectedPhoto) { _, item in
            Task {
                selectedPhotoData = try? await item?.loadTransferable(type: Data.self)
            }
        }
        .onChange(of: focusedNameField) { oldField, _ in
            guard let oldField else { return }
            touchedNameFields.insert(oldField)
            switch oldField {
            case .firstName:
                firstName = ProfileIdentityValidator.normalizedName(firstName)
            case .lastName:
                lastName = ProfileIdentityValidator.normalizedName(lastName)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IdentityInputField(
                    title: "First name",
                    placeholder: "",
                    text: $firstName,
                    focusedField: $focusedNameField,
                    field: .firstName,
                    textContentType: .givenName,
                    feedback: settingsNameFeedback(
                        validation: ProfileIdentityValidator.firstName(firstName),
                        field: .firstName
                    ),
                    onSubmit: { focusedNameField = .lastName }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                IdentityInputField(
                    title: "Last name",
                    placeholder: "",
                    text: $lastName,
                    focusedField: $focusedNameField,
                    field: .lastName,
                    textContentType: .familyName,
                    submitLabel: .done,
                    feedback: settingsNameFeedback(
                        validation: settingsLastNameValidation,
                        field: .lastName
                    ),
                    onSubmit: { focusedNameField = nil }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldRow(label: "HOME COURT") {
                    TextField("Add your home court", text: $homeCourt)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .cardStyle()
        }
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
        .disabled(!nameIsValid || store.isBusy)
        .opacity(!nameIsValid || store.isBusy ? 0.5 : 1)
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
        if let storedFirstName = profile.firstName, !storedFirstName.isEmpty,
           let storedLastName = profile.lastName, !storedLastName.isEmpty {
            firstName = storedFirstName
            lastName = storedLastName
        } else {
            let nameParts = Self.splitName(profile.displayName)
            firstName = nameParts.first
            lastName = nameParts.last
        }
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
        firstName = ProfileIdentityValidator.normalizedName(firstName)
        lastName = ProfileIdentityValidator.normalizedName(lastName)
        let photoData = selectedPhotoData
        // The two writes touch different columns, so run them concurrently to
        // overlap their network round trips.
        async let profileSaved = store.updateProfile(
            firstName: firstName,
            lastName: lastName,
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

    private var nameIsValid: Bool {
        ProfileIdentityValidator.firstName(firstName).isValid
            && settingsLastNameValidation.isValid
    }

    private var settingsLastNameValidation: IdentityValidationResult {
        let lastNameResult = ProfileIdentityValidator.lastName(lastName)
        guard lastNameResult.isValid else { return lastNameResult }
        return ProfileIdentityValidator.combinedName(firstName: firstName, lastName: lastName)
    }

    private func settingsNameFeedback(
        validation: IdentityValidationResult,
        field: NameField
    ) -> IdentityFieldFeedback {
        if touchedNameFields.contains(field), let error = validation.errorMessage {
            return .invalid(error)
        }
        return .none
    }

    private static func splitName(_ displayName: String) -> (first: String, last: String) {
        let parts = displayName.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return ("", "") }
        return (String(first), parts.dropFirst().joined(separator: " "))
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

// MARK: - Settings: Legal

/// One of the app's legal documents. Rendered in-app from bundled text so the
/// documents are readable without a live website (App Store reviewers use the
/// pre-onboarded demo account and never pass through the sign-up consent gate,
/// so this is where they can verify our Terms/Privacy and the UGC policy).
enum LegalDoc: String, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: return "Terms of Use"
        case .privacy: return "Privacy Policy"
        }
    }

    var body: String {
        switch self {
        case .terms: return LegalText.terms
        case .privacy: return LegalText.privacy
        }
    }

    var url: String {
        switch self {
        case .terms: return Legal.termsURL
        case .privacy: return Legal.privacyURL
        }
    }
}

struct SettingsLegalView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LegalDocRow(doc: .terms)
                LegalDocRow(doc: .privacy)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Legal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LegalDocRow: View {
    let doc: LegalDoc

    var body: some View {
        NavigationLink {
            LegalDocumentView(doc: doc)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentSoft, in: Circle())

                Text(doc.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .cardStyle()
    }
}

/// Renders a legal document's markdown. Uses `.inlineOnlyPreservingWhitespace`
/// so paragraph breaks are kept and inline styling (bold, links) is applied.
struct LegalDocumentView: View {
    let doc: LegalDoc

    var body: some View {
        ScrollView {
            Text(rendered)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: doc.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(doc.body)
    }
}

/// Draft legal copy shown in-app. NOTE: this is a starting point, not
/// legal advice — have counsel review before launch, and keep it in sync with
/// the hosted copies at `Legal.termsURL` / `Legal.privacyURL`.
enum LegalText {
    static let terms = """
    **Effective date: July 15, 2026**

    Welcome to pickleball.ai ("the App"). These Terms of Use ("Terms") are a legal agreement between you and pickleball.ai ("we", "us"). By creating an account or using the App, you agree to these Terms. If you do not agree, do not use the App.

    **1. Eligibility**
    You must be at least 13 years old to use the App. If you are under the age of majority where you live, you may only use the App with the involvement of a parent or guardian.

    **2. Your account**
    You sign in with your phone number and a one-time code. You are responsible for activity on your account and for keeping access to your phone number secure.

    **3. Content you post**
    You keep ownership of the sessions, comments, photos, and other content you post ("Your Content"). You grant us a non-exclusive, worldwide, royalty-free license to host, store, and display Your Content solely to operate and improve the App. You are responsible for Your Content and confirm you have the rights to share it.

    **4. Community rules — zero tolerance for objectionable content and abusive users**
    We have zero tolerance for objectionable content or abusive behavior. You agree not to post content or engage in conduct that is unlawful, harassing, bullying, threatening, hateful, defamatory, sexually explicit, violent, or that impersonates others, invades privacy, promotes cheating, or is spam. This is not an exhaustive list.

    We reserve the right, but are not obligated, to review content. When we receive a report of objectionable content or abusive behavior, we act on it — including removing the content and ejecting the user who provided it — generally within 24 hours. You can report content or users from within the App (tap the "•••" menu on a profile, post, or comment) and block users at any time.

    **5. Termination**
    We may suspend or terminate your access to the App at any time if you violate these Terms. You may stop using the App at any time and can permanently delete your account from Settings → Account.

    **6. Disclaimers**
    The App is provided "as is" and "as available," without warranties of any kind. We do not guarantee that the App will be uninterrupted, secure, or error-free.

    **7. Limitation of liability**
    To the fullest extent permitted by law, we will not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, arising from your use of the App.

    **8. Changes to these Terms**
    We may update these Terms from time to time. If we make material changes, we will notify you within the App or by other reasonable means. Continued use after changes take effect means you accept the updated Terms.

    **9. Apple App Store**
    These Terms are between you and us, not Apple. Apple is not responsible for the App or its content. Apple and its subsidiaries are third-party beneficiaries of these Terms and may enforce them against you. Apple has no obligation to provide support or maintenance for the App.

    **10. Contact**
    Questions about these Terms? Contact us at drewmanley16@gmail.com.
    """

    static let privacy = """
    **Effective date: July 15, 2026**

    This Privacy Policy explains what pickleball.ai ("we", "us") collects and how we use it. By using the App you agree to this policy.

    **1. Information we collect**
    • Phone number — used to create and sign in to your account (via SMS one-time code).
    • Profile information — display name, username, skill/rating, home court, and any photo you choose to add.
    • Content — sessions, comments, likes, and other content you create.
    • Contacts — if you choose to find friends, we match your contacts' phone numbers once to look for existing users. Contacts are matched in the moment and are not stored.
    • Device tokens — if you enable notifications, we store a push token to deliver them.
    • Basic usage/diagnostic data needed to operate the service.

    **2. How we use information**
    We use your information to operate the App: to authenticate you, show your feed and profile, deliver notifications, enable social features (follows, comments, contact matching), and to keep the community safe (handling reports, blocks, and abuse).

    **3. How information is shared**
    We share information with service providers who help us run the App, including our backend host (Supabase), our SMS provider (Twilio, to send your login code), and Apple Push Notification service (to deliver notifications). We do not sell your personal information. We may disclose information if required by law.

    **4. Data retention and deletion**
    We keep your information for as long as your account is active. You can permanently delete your account and associated content at any time from Settings → Account → Delete Account.

    **5. Your choices**
    You control your profile information, whether to grant Contacts and Notifications permissions, and can block or report other users at any time.

    **6. Children**
    The App is not intended for children under 13, and we do not knowingly collect information from them.

    **7. Changes to this policy**
    We may update this policy from time to time and will notify you of material changes within the App or by other reasonable means.

    **8. Contact**
    Questions about privacy? Contact us at drewmanley16@gmail.com.
    """
}
