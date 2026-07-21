import SwiftUI

/// One-tap start. Optional target-score and serve pickers before the first
/// point — no player identities on the wrist (attached on the phone).
struct GameSetupView: View {
    @EnvironmentObject var store: WatchGameStore

    private let targets = [11, 15, 21]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("New Game")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Target score
                VStack(alignment: .leading, spacing: 4) {
                    Text("Play to")
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.dimText)
                    HStack(spacing: 6) {
                        ForEach(targets, id: \.self) { value in
                            Button {
                                store.setTarget(value)
                                Haptics.play(.click)
                            } label: {
                                Text("\(value)")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 8)
                            .background(store.game.target == value ? WatchTheme.lime : Color.white.opacity(0.12))
                            .foregroundStyle(store.game.target == value ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                // Serve indicator
                Button {
                    store.toggleServe()
                } label: {
                    HStack {
                        Text("Serve")
                        Spacer()
                        Text(store.game.serving == .us ? "US" : "THEM")
                            .fontWeight(.semibold)
                            .foregroundStyle(WatchTheme.lime)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    store.startGame()
                } label: {
                    Text("Start")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .background(WatchTheme.lime)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .background(WatchTheme.background)
    }
}
