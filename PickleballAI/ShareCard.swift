import SwiftUI
import UIKit

/// A branded, screenshot-ready scorecard for a session — this is what turns a
/// logged match into something people post in the group chat. Rendered to a
/// UIImage via `ImageRenderer` (see `renderShareImage`), so it must stay
/// synchronous: no `RemoteImage`/async avatars, initials only.
struct SessionShareCard: View {
    let session: FeedSession

    private var matches: [SessionActivity] { session.postActivities }
    private var wins: Int { matches.filter { $0.matchResult == .win }.count }
    private var losses: Int { matches.filter { $0.matchResult == .loss }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Wordmark
            HStack(spacing: 8) {
                Image(systemName: "figure.pickleball")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                Text("piclr")
                    .font(.headline.weight(.heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(session.postDate.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            // Who + title
            HStack(spacing: 12) {
                Text(session.postAuthor.initials)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.postAuthor.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(session.postDisplayTitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if !matches.isEmpty {
                // Big record
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(wins)")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.accent)
                    Text("–")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(losses)")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("W–L")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(matches.prefix(4).enumerated()), id: \.element.id) { index, m in
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        HStack {
                            Text("Match \(index + 1)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(m.scoreLine ?? "-")
                                .font(.callout.weight(.bold).monospacedDigit())
                                .foregroundStyle(m.matchResult?.color ?? Theme.textPrimary)
                            if let result = m.matchResult {
                                Text(result.badge)
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(result == .tie ? Theme.textPrimary : Theme.background)
                                    .frame(width: 22, height: 22)
                                    .background(result.color, in: Circle())
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }

            if let location = session.postLocation, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }
}

/// Renders a session's scorecard to a high-resolution image for sharing.
@MainActor
func renderShareImage(for session: FeedSession) -> UIImage? {
    let renderer = ImageRenderer(
        content: SessionShareCard(session: session)
            .padding(16)
            .background(Theme.background)
    )
    renderer.scale = 3
    return renderer.uiImage
}

/// The Pro "weekly wrap" scorecard — richer than the free `SessionShareCard`
/// (streak + hot-rival callouts a single session can't show), fulfilling the
/// paywall's "Shareable cards" promise. Only reachable from `WeeklyWrapSheet`,
/// itself Pro-gated, so no extra lock check is needed here.
struct WeeklyWrapShareCard: View {
    let wrap: WeekWrap

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "figure.pickleball")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                Text("piclr")
                    .font(.headline.weight(.heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("WEEK OF \(wrap.weekStart.formatted(.dateTime.month(.abbreviated).day()))".uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(wrap.headline)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                shareStat(value: "\(wrap.sessions)", label: "Sessions")
                shareStat(value: String(format: "%.1f", wrap.hours), label: "Hours")
                shareStat(value: "\(wrap.wins)–\(wrap.losses)", label: "Record")
            }

            if wrap.weeklyStreak > 0 {
                Label("\(wrap.weeklyStreak)-week streak", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            if let rival = wrap.hotRival {
                HStack(spacing: 10) {
                    Image(systemName: "flame.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(rival.theyAreHot ? Theme.loss : Theme.accent)
                    Text(rival.person.displayName + ": " + rival.momentumLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    private func shareStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders a Pro weekly-wrap scorecard to a high-resolution image for sharing.
@MainActor
func renderShareImage(for wrap: WeekWrap) -> UIImage? {
    let renderer = ImageRenderer(
        content: WeeklyWrapShareCard(wrap: wrap)
            .padding(16)
            .background(Theme.background)
    )
    renderer.scale = 3
    return renderer.uiImage
}

/// Identifiable wrapper so a freshly-rendered image can drive a `.sheet(item:)`.
struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let caption: String
}

/// Thin bridge to the system share sheet, sharing the image plus a text caption.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let payload: ShareImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [payload.image, payload.caption], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
