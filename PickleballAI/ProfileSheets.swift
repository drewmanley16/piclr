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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var didSave = false

    private let sides = ["Left", "Right", "Both"]

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
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }

                Section {
                    Button(role: .destructive) {
                        Task { await store.signOut(); dismiss() }
                    } label: {
                        Text("Log out").frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private func saveProfile() async {
        didSave = false
        let profileSaved = await store.updateProfile(
            displayName: displayName,
            homeCourt: homeCourt,
            rating: Double(rating),
            preferredSide: preferredSide
        )
        guard profileSaved else { return }
        if let selectedPhotoData {
            guard await store.uploadProfilePhoto(selectedPhotoData) else { return }
            self.selectedPhotoData = nil
            selectedPhoto = nil
        }
        didSave = true
    }
}
