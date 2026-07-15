import WidgetKit
import SwiftUI
import ActivityKit

private let accent = Color(red: 197/255, green: 1, blue: 61/255)   // Theme.accent
private let background = Color.black

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // Lock screen / banner
            LockScreenView(context: context)
                .padding(16)
                .background(background)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Live", systemImage: "circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .labelStyle(.titleAndIcon)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(accent)
                        .frame(maxWidth: 64)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(activityLabel(context.state.activityCount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.pickleball").foregroundStyle(accent)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "figure.pickleball").foregroundStyle(accent)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 46, height: 46)
                Image(systemName: "figure.pickleball").foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(activityLabel(context.state.activityCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(maxWidth: 90)
                    .multilineTextAlignment(.trailing)
                Text("in progress")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private func activityLabel(_ count: Int) -> String {
    count == 0 ? "Tap to log a game" : (count == 1 ? "1 game logged" : "\(count) games logged")
}

@main
struct PickleballWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}
