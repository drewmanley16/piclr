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

    var body: some View {
        NavigationStack {
            ScrollView {
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
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
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
    @EnvironmentObject private var store: AppStore
    @AppStorage("notificationsEnabled") private var notifications = true
    @State private var displayName = ""
    @State private var homeCourt = ""
    @State private var rating = ""
    @State private var preferredSide = "Left"
    @State private var birthdaySet = false
    @State private var birthdayDate = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var didSave = false
    @State private var showBlockedAccounts = false
    @State private var showDeleteAccount = false

    private let sides = ["Left", "Right", "Both"]

    private static let birthdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            VStack(spacing: 8) {
                                profilePhoto
                                Text("Change Photo")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    LabeledContent("Username", value: store.currentProfile.map { "@\($0.username)" } ?? "—")
                    TextField("Display name", text: $displayName)
                    TextField("Home court", text: $homeCourt)
                }

                Section("Player Details") {
                    TextField("Rating (DUPR)", text: $rating)
                        .keyboardType(.decimalPad)
                    Picker("Preferred side", selection: $preferredSide) {
                        ForEach(sides, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Birthday") {
                    Toggle("Add birthday", isOn: $birthdaySet.animation())
                        .tint(Theme.accent)
                    if birthdaySet {
                        DatePicker("Birthday", selection: $birthdayDate, in: ...Date(), displayedComponents: .date)
                            .tint(Theme.accent)
                    }
                }

                Section {
                    Button {
                        Task { await saveProfile() }
                    } label: {
                        Text(store.isBusy ? "Saving..." : "Save Profile")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(displayName.isEmpty || store.isBusy)
                    .listRowBackground(Theme.accent)
                }

                if didSave {
                    Section {
                        Label("Profile saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                } else if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Preferences") {
                    Toggle(isOn: $notifications) {
                        Label("Push notifications", systemImage: "bell")
                    }
                    Button {
                        showBlockedAccounts = true
                    } label: {
                        Label("Blocked Accounts", systemImage: "person.crop.circle.badge.xmark")
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }

                Section {
                    Button(role: .destructive) {
                        Task { await store.signOut(); dismiss() }
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(role: .destructive) {
                        showDeleteAccount = true
                    } label: {
                        Label("Delete Account", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { loadProfile() }
            .onChange(of: selectedPhoto) { _, item in
                didSave = false
                Task {
                    selectedPhotoData = try? await item?.loadTransferable(type: Data.self)
                }
            }
            .sheet(isPresented: $showBlockedAccounts) {
                BlockedAccountsView()
            }
            .sheet(isPresented: $showDeleteAccount) {
                DeleteAccountSheet()
            }
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
        didSave = false
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
        didSave = true
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
