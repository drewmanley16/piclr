import SwiftUI

enum GearShowcaseLayout {
    static let cardWidth: CGFloat = 132
    static let iconSize: CGFloat = 44
}

/// An item's photo in a circle, falling back to its category icon when there
/// isn't one — same footprint either way, so a part-photographed locker still
/// lines up. Shared by the locker rows and the profile showcase.
struct GearThumbnail: View {
    var item: GearItem
    var size: CGFloat = GearShowcaseLayout.iconSize

    var body: some View {
        Group {
            if let photo = item.photoUrl, let url = URL(string: photo) {
                RemoteImage(url: url)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Image(systemName: item.categoryIcon)
                    .font(size > 56 ? .title : .title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: size, height: size)
                    .background(Theme.accentSoft, in: Circle())
            }
        }
        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// The gear locker as a display piece: a horizontal strip of gear cards shown
/// on a profile, with "See all" opening the full locker. Renders nothing when
/// the locker is empty — on your own profile the Gear dashboard tile is still
/// the way in, and on someone else's an empty locker (hidden, or genuinely
/// empty) should leave no trace.
struct GearShowcaseRow: View {
    var items: [GearItem]
    /// Set on your own profile when you've switched the locker off, so it's
    /// obvious the row you're looking at isn't the one others see.
    var isHidden = false
    var onSeeAll: () -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                Haptics.tap()
                                onSeeAll()
                            } label: {
                                GearShowcaseCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("GEAR")
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            if isHidden { hiddenChip }
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                onSeeAll()
            } label: {
                HStack(spacing: 3) {
                    Text("See all")
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var hiddenChip: some View {
        Label("Hidden", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceElevated, in: Capsule())
    }
}

/// One item in the showcase strip: category icon, name, and the same
/// `brand · category` subtitle the locker rows use.
struct GearShowcaseCard: View {
    var item: GearItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GearThumbnail(item: item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: GearShowcaseLayout.cardWidth, alignment: .leading)
        .cardStyle(padding: 0)
    }
}
