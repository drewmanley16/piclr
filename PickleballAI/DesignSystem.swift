import SwiftUI
import UIKit

// MARK: - Theme Tokens

/// Central design tokens, rooted in a pickleball court at night:
/// a deep blue-black base (not generic pure black), cool charcoal surfaces,
/// and one optic-green accent kept in reserve for performance / wins.
enum Theme {
    // Surfaces — true black base with cards that sit just a whisper above it, so
    // posts read as one seamless black surface (separated by spacing, not boxes).
    static let background = Color(hex: 0x000000)        // true black
    static let surface = Color(hex: 0x0F0F0F)          // card — barely lifted from black
    static let surfaceElevated = Color(hex: 0x212121)  // chips / tiles / nested

    // Accent — the optic green of a pickleball. Reserved for wins/performance.
    static let accent = Color(hex: 0xC5FF3D)
    static var accentSoft: Color { accent.opacity(0.14) }

    // Semantic result colors (a match is won or lost — both must read at a glance).
    static let win = Color(hex: 0xC5FF3D)              // optic green
    static let loss = Color(hex: 0xF0785A)             // court clay

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)

    // Lines
    static let hairline = Color.white.opacity(0.08)
    static let courtLine = Color.white.opacity(0.14)   // chalk line on the scoreboard

    // Radii (continuous = Apple squircle)
    static let radiusCard: CGFloat = 18
    static let radiusControl: CGFloat = 12

    /// Courtside scoreboard numerals: heavy, rounded, tabular so scores line up.
    static func scoreboard(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }
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
    var bordered: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: bordered ? 1 : 0)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16, fill: Color = Theme.surface, bordered: Bool = true) -> some View {
        modifier(CardStyle(padding: padding, fill: fill, bordered: bordered))
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

/// Loads a remote image with retries so a slow/blipped first load doesn't get
/// stuck on the placeholder forever (AsyncImage never retries a failed load).
struct RemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    /// Decoded-image cache shared across all instances so a URL that's already
    /// been loaded renders instantly on re-appear (scrolling, navigation) with
    /// no flash or re-download.
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.surfaceElevated)
                    .overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(Theme.textTertiary)
                        } else {
                            ProgressView().tint(Theme.textTertiary)
                        }
                    }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        // Cache hit → show immediately, skip the network entirely.
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        for _ in 0..<4 {
            if Task.isCancelled { return }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let img = UIImage(data: data) {
                Self.cache.setObject(img, forKey: url as NSURL)
                image = img
                return
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        failed = true
    }
}

/// The single avatar component used everywhere. Shows the profile photo when a
/// URL is available (with retries via `RemoteImage`) and falls back to initials
/// otherwise. Build it from a `Profile`, a `ParticipantProfile`, or raw
/// url/initials so every call site renders photos consistently.
struct ProfileAvatar: View {
    var url: String?
    var initials: String
    var size: CGFloat

    init(url: String?, initials: String, size: CGFloat = 44) {
        self.url = url
        self.initials = initials.isEmpty ? "PB" : initials
        self.size = size
    }

    init(profile: Profile?, size: CGFloat = 44) {
        self.init(url: profile?.avatarURL, initials: profile?.initials ?? "PB", size: size)
    }

    init(participant: ParticipantProfile?, size: CGFloat = 44) {
        self.init(url: participant?.avatarURL, initials: participant?.initials ?? "?", size: size)
    }

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                RemoteImage(url: parsed)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityLabel("Profile photo")
    }

    private var fallback: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceElevated)
    }
}

/// Capsule three-way selector styled after a court split down the middle —
/// used for "Preferred side" instead of a native segmented Picker.
struct SideSelector: View {
    var sides: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sides, id: \.self) { side in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = side }
                } label: {
                    Text(side)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == side ? Theme.background : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            selection == side ? Theme.accent : Color.clear,
                            in: Capsule()
                        )
                }
            }
        }
        .padding(4)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Bottom-anchored confirmation toast. Bind `isPresented` and it auto-dismisses
/// itself after `duration` seconds — callers don't need their own timer.
struct Toast: ViewModifier {
    @Binding var isPresented: Bool
    var message: String
    var systemImage: String = "checkmark.circle.fill"
    var duration: TimeInterval = 2.0

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isPresented {
                Label(message, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: isPresented) {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        withAnimation { isPresented = false }
                    }
            }
        }
        .animation(.snappy, value: isPresented)
    }
}

extension View {
    func toast(isPresented: Binding<Bool>, message: String, systemImage: String = "checkmark.circle.fill") -> some View {
        modifier(Toast(isPresented: isPresented, message: message, systemImage: systemImage))
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
