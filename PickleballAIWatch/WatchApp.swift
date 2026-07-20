import SwiftUI

/// Watch app entry point. A single `WatchGameStore` owns the live game and the
/// WC link for the whole app lifetime.
@main
struct PickleballAIWatchApp: App {
    @StateObject private var store = WatchGameStore()

    var body: some Scene {
        WindowGroup {
            RootWatchView()
                .environmentObject(store)
        }
    }
}

/// Routes between the three watch phases. Kept deliberately tiny — the whole
/// point of the wrist flow is that there is almost nothing to it.
struct RootWatchView: View {
    @EnvironmentObject var store: WatchGameStore

    var body: some View {
        // A NavigationStack gives the scoring screen a top bar to host the undo
        // button + target label (watchOS `.toolbar` items render nowhere without
        // an enclosing navigation container).
        NavigationStack {
            switch store.phase {
            case .setup:    GameSetupView()
            case .playing:  ScoreView()
            case .gameOver: GameOverView()
            }
        }
    }
}

// MARK: - Watch-local theme
//
// The watch target doesn't compile the app's DesignSystem.swift, so the small
// slice of tokens the wrist UI needs lives here — same all-black + electric-lime.
enum WatchTheme {
    static let lime = Color(red: 0.79, green: 1.0, blue: 0.0)
    static let background = Color.black
    static let dimText = Color.white.opacity(0.5)
    static let usTint = lime
    static let themTint = Color.white.opacity(0.85)
}
