import PhotosUI
import SwiftUI

// MARK: - Gear

struct GearSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    var mode: GearLockerMode = .owner
    @State private var showAdd = false
    @State private var editing: GearItem?
    @State private var showOnProfile = true
    @State private var isSavingVisibility = false

    private var isOwner: Bool {
        if case .owner = mode { return true }
        return false
    }

    private var items: [GearItem] {
        switch mode {
        case .owner: return store.gear
        case .viewer(_, let items): return items
        }
    }

    private var title: String {
        switch mode {
        case .owner: return "My Gear"
        case .viewer(let name, _): return "\(name)'s Gear"
        }
    }

    /// Gear grouped into sections by category, in the category enum's order, so
    /// the locker reads as an organized set of shelves rather than a flat list.
    private var sections: [(category: GearCategory, items: [GearItem])] {
        GearCategory.allCases.compactMap { category in
            let matching = items.filter { $0.category == category.rawValue }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        if isOwner { visibilityToggle }
                        ForEach(sections, id: \.category) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.category.rawValue.uppercased())
                                    .font(.caption.weight(.bold))
                                    .tracking(0.8)
                                    .foregroundStyle(Theme.textTertiary)
                                ForEach(section.items) { item in
                                    GearRow(item: item, isOwner: isOwner) { editing = item }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if isOwner {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddGearSheet().presentationDetents([.large]) }
            .sheet(item: $editing) { EditGearSheet(item: $0).presentationDetents([.large]) }
            .onAppear { showOnProfile = store.currentProfile?.gearVisible ?? true }
        }
    }

    /// The one privacy control for the locker. Lives here rather than in
    /// Settings because this is where you're already thinking about your gear.
    private var visibilityToggle: some View {
        Toggle(isOn: $showOnProfile) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Show on profile", systemImage: "eye")
                    .foregroundStyle(Theme.textPrimary)
                Text("Anyone who can see your profile can see your gear")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.accent)
        .disabled(isSavingVisibility)
        .onChange(of: showOnProfile) { _, visible in
            guard visible != (store.currentProfile?.gearVisible ?? true) else { return }
            Haptics.tap()
            isSavingVisibility = true
            Task {
                // Serialized by `isSavingVisibility` disabling the toggle
                // mid-flight, so this can't race a second in-flight write.
                let succeeded = await store.setGearVisible(visible)
                if !succeeded { showOnProfile = !visible }
                isSavingVisibility = false
            }
        }
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bag.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text(isOwner ? "Build your locker" : "No gear yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(isOwner
                 ? "Add your paddles, balls, shoes, and more to keep your setup in one place."
                 : "This player hasn't shared any gear.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if isOwner {
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
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .padding(.top, 60)
    }
}

struct GearRow: View {
    @Environment(AppStore.self) private var store
    var item: GearItem
    /// Only the owner gets the edit tap and remove menu; a viewer's locker is
    /// read-only.
    var isOwner = true
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            // A Button rather than `.onTapGesture` so "edit this item" is a real
            // accessibility action — VoiceOver users and UI automation both need
            // it exposed, not just reachable by touch.
            if isOwner {
                Button {
                    Haptics.tap()
                    onEdit?()
                } label: {
                    details
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens gear details")
            } else {
                details
            }

            Spacer(minLength: 0)

            if isOwner {
                Menu {
                    Button {
                        onEdit?()
                    } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) {
                        Task { await store.deleteGear(item) }
                    } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Gear actions")
            }
        }
        .cardStyle()
    }

    private var details: some View {
        HStack(spacing: 14) {
            GearThumbnail(item: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(item.subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct AddGearSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    @State private var category = GearCategory.paddle
    @State private var name = ""
    @State private var brand = ""
    @State private var photo = GearPhotoSelection()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GearFormFields(
                        category: $category,
                        name: $name,
                        brand: $brand,
                        photo: $photo,
                        storedPhotoURL: nil
                    )

                    Button {
                        Task {
                            let saved = await store.addGear(
                                category: category.rawValue,
                                name: name,
                                brand: brand,
                                photo: photo.pickedData
                            )
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

struct EditGearSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    let item: GearItem

    @State private var category: GearCategory
    @State private var name: String
    @State private var brand: String
    @State private var photo = GearPhotoSelection()

    init(item: GearItem) {
        self.item = item
        _category = State(initialValue: GearCategory(rawValue: item.category) ?? .other)
        _name = State(initialValue: item.name)
        _brand = State(initialValue: item.brand ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GearFormFields(
                        category: $category,
                        name: $name,
                        brand: $brand,
                        photo: $photo,
                        storedPhotoURL: item.photoUrl
                    )

                    Button {
                        Task {
                            let saved = await store.updateGear(
                                item,
                                category: category.rawValue,
                                name: name,
                                brand: brand,
                                photo: photo.edit
                            )
                            if saved { Haptics.success(); dismiss() }
                        }
                    } label: {
                        Text(store.isBusy ? "Saving…" : "Save changes")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(name.isEmpty || store.isBusy)
                    .opacity(name.isEmpty || store.isBusy ? 0.5 : 1)

                    Button(role: .destructive) {
                        Task {
                            await store.deleteGear(item)
                            Haptics.success()
                            dismiss()
                        }
                    } label: {
                        Label("Remove from locker", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)

                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Edit Gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { store.errorMessage = nil }
        }
    }
}

/// What the user has done to a form's photo. Holds the picked image for an
/// instant preview and folds down to the `GearPhotoEdit` the store wants.
struct GearPhotoSelection {
    var pickedImage: UIImage?
    var pickedData: Data?
    var clearedStored = false

    var edit: GearPhotoEdit {
        if let pickedData { return .replaced(pickedData) }
        return clearedStored ? .removed : .unchanged
    }
}

/// Category grid + name/brand + photo, shared by the Add and Edit sheets so the
/// two stay identical by construction.
private struct GearFormFields: View {
    @Binding var category: GearCategory
    @Binding var name: String
    @Binding var brand: String
    @Binding var photo: GearPhotoSelection
    /// The item's already-saved photo, shown until it's replaced or cleared.
    var storedPhotoURL: String?

    @State private var pickerItem: PhotosPickerItem?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var visibleStoredURL: URL? {
        guard !photo.clearedStored, photo.pickedImage == nil,
              let stored = storedPhotoURL else { return nil }
        return URL(string: stored)
    }

    private var hasPhoto: Bool { photo.pickedImage != nil || visibleStoredURL != nil }

    var body: some View {
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

            VStack(alignment: .leading, spacing: 12) {
                Text("PHOTO")
                    .font(.caption.weight(.bold)).tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 14) {
                    preview
                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(hasPhoto ? "Change photo" : "Add a photo", systemImage: "photo.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(minHeight: 36)
                        }
                        if hasPhoto {
                            Button {
                                Haptics.tap()
                                photo.pickedImage = nil
                                photo.pickedData = nil
                                photo.clearedStored = true
                                pickerItem = nil
                            } label: {
                                Label("Remove photo", systemImage: "xmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(minHeight: 36)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                photo.pickedData = data
                photo.pickedImage = image
                photo.clearedStored = false
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let size: CGFloat = 72
        if let picked = photo.pickedImage {
            Image(uiImage: picked)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let url = visibleStoredURL {
            RemoteImage(url: url)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: category.systemImage)
                .font(.title)
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
                .background(Theme.accentSoft, in: Circle())
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
