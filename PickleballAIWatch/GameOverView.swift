import SwiftUI

/// Shown when a game reaches its target. Choose "New game" (same session) or
/// "Finish & post" (the phone posts). Undo backs out if the game ended by
/// mistake.
struct GameOverView: View {
    @EnvironmentObject var store: WatchGameStore

    private var game: LiveMatchScore { store.game }
    private var didWin: Bool { game.winner == .us }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(didWin ? "You won!" : "Game over")
                    .font(.headline)
                    .foregroundStyle(didWin ? WatchTheme.lime : .white)

                Text("\(game.us)–\(game.them)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()

                WatchWorkoutMetricsView()

                Button {
                    store.newGame()
                } label: {
                    Text("New game")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .background(WatchTheme.lime)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    store.finishSession()
                } label: {
                    Text("Finish & post")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .background(WatchTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(store.workoutIsFinishing)

                Button("Undo last point") { store.undo() }
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.dimText)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
        .background(WatchTheme.background)
    }
}
