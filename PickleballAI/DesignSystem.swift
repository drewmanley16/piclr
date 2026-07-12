import SwiftUI

// MARK: - Theme Tokens

/// Central design tokens for the premium dark look:
/// pure-black base, raised charcoal surfaces, one electric-green accent.
enum Theme {
    // Surfaces
    static let background = Color(hex: 0x000000)
    static let surface = Color(hex: 0x121214)          // raised card
    static let surfaceElevated = Color(hex: 0x1E1E22)  // chips / avatars / nested

    // Accent
    static let accent = Color(hex: 0xC5FF3D)           // electric court green
    static var accentSoft: Color { accent.opacity(0.14) }

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    // Lines
    static let hairline = Color.white.opacity(0.08)

    // Radii (continuous = Apple squircle)
    static let radiusCard: CGFloat = 22
    static let radiusControl: CGFloat = 14
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Card

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    var fill: Color = Theme.surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16, fill: Color = Theme.surface) -> some View {
        modifier(CardStyle(padding: padding, fill: fill))
    }
}

// MARK: - Shared Components

struct StatPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: Circle())

            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }
}

struct AvatarView: View {
    var initials: String

    var body: some View {
        Text(initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 40, height: 40)
            .background(Theme.surfaceElevated, in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct ProfileAvatar: View {
    var profile: Profile?
    var size: CGFloat

    var body: some View {
        Group {
            if let avatarURL = profile?.avatarURL, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityLabel(profile.map { "\($0.displayName)'s profile photo" } ?? "Profile photo")
    }

    private var fallback: some View {
        Text(profile?.initials ?? "PB")
            .font(.title.weight(.bold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceElevated)
    }
}

struct SectionHeader: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
            }
        }
    }
}

// MARK: - Compact Header

/// Compact top bar: bold title (optional dropdown chevron) on the left,
/// a trailing slot for action controls on the right. Replaces large nav titles.
struct AppHeader<Trailing: View>: View {
    var title: String
    var showsChevron: Bool = false
    var onTitleTap: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onTitleTap?()
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    if showsChevron {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(Theme.surface, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(onTitleTap != nil)

            Spacer()

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

/// Capsule container that groups one or more header icon buttons (search, bell…).
struct HeaderPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 20) {
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Single circular icon button for headers (e.g. settings gear).
struct HeaderCircleButton: View {
    var systemImage: String
    var accessibilityTitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 42, height: 42)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .accessibilityLabel(accessibilityTitle)
    }
}

/// Bare icon button intended for use inside a `HeaderPill`.
struct HeaderIconButton: View {
    var systemImage: String
    var accessibilityTitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityLabel(accessibilityTitle)
    }
}

extension Date {
    var relativeLabel: String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
