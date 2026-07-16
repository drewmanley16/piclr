import SwiftUI
import PhotosUI
import UIKit

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
