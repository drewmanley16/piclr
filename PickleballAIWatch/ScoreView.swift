import SwiftUI

/// The scoring screen: two big tap targets (your side / opponents' side). A tap
/// awards the rally; a long-press on a side undoes the last point. Haptic per
/// point is fired in the store.
///
/// We deliberately avoid a `.focusable()` + Digital Crown container here — on
/// watchOS a focusable container swallows the first tap to take focus, which
/// makes the score buttons feel dead. Tap + long-press gestures coexist cleanly
/// and keep every tap instant.
struct ScoreView: View {
    @EnvironmentObject var store: WatchGameStore

    private var game: LiveMatchScore { store.game }

    var body: some View {
        VStack(spacing: 4) {
            sideButton(.us)
            sideButton(.them)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(WatchTheme.background)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("to \(game.target)")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.dimText)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .tint(WatchTheme.lime)
                .disabled(game.points.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func sideButton(_ side: Side) -> some View {
        let isServing = game.serving == side
        let isGamePoint = game.isGamePoint(for: side)
        let tint = side == .us ? WatchTheme.usTint : WatchTheme.themTint

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(side == .us ? "US" : "THEM")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(side == .us ? .black : .white)
                    if isServing {
                        Circle()
                            .fill(side == .us ? WatchTheme.scrim : WatchTheme.lime)
                            .frame(width: 6, height: 6)
                    }
                }
                if isGamePoint {
                    Text("GAME PT")
                        .font(.system(size: 8).weight(.bold))
                        .foregroundStyle(side == .us ? .black.opacity(0.7) : WatchTheme.lime)
                }
            }
            Spacer()
            Text("\(game.score(for: side))")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(side == .us ? .black : .white)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(side == .us ? tint : WatchTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isGamePoint ? WatchTheme.lime : .clear, lineWidth: side == .us ? 0 : 1.5)
        )
        .contentShape(Rectangle())
        // Tap awards the rally; long-press undoes the last point.
        .onTapGesture { store.award(side) }
        .onLongPressGesture(minimumDuration: 0.45) { store.undo() }
    }
}
