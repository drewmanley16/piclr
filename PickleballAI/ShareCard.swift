import SwiftUI
import UIKit

/// A branded, screenshot-ready scorecard for a session — this is what turns a
/// logged match into something people post in the group chat. Rendered to a
/// UIImage via `ImageRenderer` (see `renderShareImage`), so it must stay
/// synchronous: no `RemoteImage`/async avatars, initials only.
struct SessionShareCard: View {
    let session: FeedSession

    private var matches: [SessionActivity] { session.sortedActivities.filter { $0.isMatch } }
    private var wins: Int { matches.filter { $0.won == true }.count }
    private var losses: Int { matches.filter { $0.won == false }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Wordmark
            HStack(spacing: 8) {
                Image(systemName: "figure.pickleball")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                Text("pickleball.ai")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(session.date.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            // Who + title
            HStack(spacing: 12) {
                Text(session.author.initials)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.author.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(session.displayTitle)
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
                            Text(m.scoreLine ?? "—")
                                .font(.callout.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                            if let won = m.won {
                                Text(won ? "W" : "L")
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(Theme.background)
                                    .frame(width: 22, height: 22)
                                    .background(won ? Theme.win : Theme.loss, in: Circle())
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }

            if let location = session.location, !location.isEmpty {
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
