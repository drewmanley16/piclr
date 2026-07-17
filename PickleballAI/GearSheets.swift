import SwiftUI

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
