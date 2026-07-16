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

    // Semantic result colors (a match is won, lost, or tied — all must read at a glance).
    static let win = Color(hex: 0xC5FF3D)              // optic green
    static let loss = Color(hex: 0xF0785A)             // court clay
    static let tie = Color.white.opacity(0.55)         // neutral — no winner

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

extension MatchResult {
    /// Green win / red loss / neutral tie — the app's at-a-glance result colors.
    var color: Color {
        switch self {
        case .win:  return Theme.win
        case .loss: return Theme.loss
        case .tie:  return Theme.tie
        }
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

struct SocialAction: View {
    var icon: String
    var count: Int?

    var body: some View {
        Button {
        } label: {
            SocialLabel(icon: icon, count: count)
        }
        .buttonStyle(.plain)
    }
}

struct SocialLabel: View {
    var icon: String
    var count: Int?
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                // Spring "pop" when the icon becomes highlighted (a like landing).
                .scaleEffect(isHighlighted ? 1.18 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.45), value: isHighlighted)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy, value: count)
            }
        }
        .foregroundStyle(isHighlighted ? Theme.accent : Theme.textSecondary)
        .frame(minHeight: 44)
        .animation(.easeInOut(duration: 0.16), value: isHighlighted)
    }
}

struct FocusChip: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.accentSoft, in: Capsule())
            .foregroundStyle(Theme.accent)
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
    /// The user this avatar represents, when known. Enables `linked`.
    var userId: UUID?
    /// When true (and `userId` is known), tapping the avatar pushes that user's
    /// profile — routed through `ProfileLink` so navigation stays defined in one
    /// place. Off by default so avatars in pickers, editors, or rows that are
    /// already navigation links don't double-navigate.
    var linked: Bool = false

    init(url: String?, initials: String, size: CGFloat = 44, userId: UUID? = nil, linked: Bool = false) {
        self.url = url
        self.initials = initials.isEmpty ? "PB" : initials
        self.size = size
        self.userId = userId
        self.linked = linked
    }

    init(profile: Profile?, size: CGFloat = 44, linked: Bool = false) {
        self.init(url: profile?.avatarURL, initials: profile?.initials ?? "PB", size: size, userId: profile?.id, linked: linked)
    }

    init(participant: ParticipantProfile?, size: CGFloat = 44, linked: Bool = false) {
        self.init(url: participant?.avatarURL, initials: participant?.initials ?? "?", size: size, userId: participant?.id, linked: linked)
    }

    var body: some View {
        if linked, let userId {
            ProfileLink(userId: userId) { circle }
        } else {
            circle
        }
    }

    private var circle: some View {
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

/// Action for "open this user's profile," injected via the environment so the
/// design system never imports a feature screen. The app wires the concrete
/// destination once (see `ProfileNavigationStack`); here we only know a user was
/// tapped. Also drives programmatic opens (deep links, notifications).
struct OpenProfileAction {
    let handler: (UUID, Profile?) -> Void
    func callAsFunction(_ userId: UUID, placeholder: Profile? = nil) {
        handler(userId, placeholder)
    }
}

private struct OpenProfileKey: EnvironmentKey {
    /// No-op default: a tap in a context that hasn't wired navigation simply does
    /// nothing rather than crashing.
    static let defaultValue = OpenProfileAction { _, _ in }
}

extension EnvironmentValues {
    var openProfile: OpenProfileAction {
        get { self[OpenProfileKey.self] }
        set { self[OpenProfileKey.self] = newValue }
    }
}

/// Wraps its content in a tap target that opens the tapped user's profile via the
/// `openProfile` environment action, so avatars and names navigate consistently
/// everywhere (Instagram-style). Pass a `nil` `userId` to render the content
/// inert — e.g. selection UIs or your own rows where navigation isn't wanted.
/// The enclosing screen must provide the action (use `ProfileNavigationStack`).
struct ProfileLink<Content: View>: View {
    @Environment(\.openProfile) private var openProfile
    var userId: UUID?
    var placeholder: Profile?
    @ViewBuilder var content: Content

    init(userId: UUID?, placeholder: Profile? = nil, @ViewBuilder content: () -> Content) {
        self.userId = userId
        self.placeholder = placeholder
        self.content = content()
    }

    var body: some View {
        if let userId {
            Button {
                openProfile(userId, placeholder: placeholder)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Two-or-more-way capsule segmented control — the discoverable replacement for
/// hiding a mode switch behind a menu. Selection is a plain equatable value so
/// callers bind their own enum. Fires a light haptic on change.
struct SegmentedControl<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Button {
                    guard !isSelected else { return }
                    Haptics.tap()
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Theme.background : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            isSelected ? Theme.accent : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// A single sweeping highlight used by skeleton placeholders so loading states
/// read as "content is coming" rather than a dead spinner.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 1.5)
                    .offset(x: phase * geo.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Ghost of a `FeedCard` shown while the first page of the feed loads, so the
/// feed feels populated instantly instead of blank-then-spinner.
struct FeedCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(Theme.surfaceElevated).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 120, height: 12)
                    bar(width: 80, height: 10)
                }
                Spacer()
            }
            bar(width: 180, height: 14)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surfaceElevated)
                .frame(height: 54)
            HStack(spacing: 20) {
                bar(width: 40, height: 12)
                bar(width: 40, height: 12)
                Spacer()
            }
        }
        .cardStyle(bordered: false)
        .shimmer()
        .redacted(reason: .placeholder)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Theme.surfaceElevated)
            .frame(width: width, height: height)
    }
}

/// Ghost of an avatar + two-line row, for list loads (profiles, leaderboard,
/// sessions) — the row equivalent of `FeedCardSkeleton`.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.surfaceElevated).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceElevated).frame(width: 140, height: 12)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surfaceElevated).frame(width: 90, height: 10)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .shimmer()
        .redacted(reason: .placeholder)
    }
}

/// A column of `SkeletonRow`s in a card, for whole-list loading states.
struct SkeletonList: View {
    var rows = 5
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { _ in SkeletonRow() }
        }
        .cardStyle()
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
