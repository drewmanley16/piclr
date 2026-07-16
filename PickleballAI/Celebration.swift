import SwiftUI

/// The payoff moment after posting a session: a springing accent checkmark over
/// a short burst of confetti. Self-contained and time-boxed by the caller (show
/// it, wait ~1s, dismiss). Purely decorative, so it ignores hit testing.
struct CelebrationView: View {
    var title: String = "Posted!"
    @State private var badgeIn = false

    var body: some View {
        ZStack {
            // swiftlint:disable:next hardcoded_color — deliberate dimming scrim, not a themed surface
            Color.black.opacity(0.35).ignoresSafeArea()

            ConfettiBurst()

            VStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Theme.background)
                    .frame(width: 96, height: 96)
                    .background(Theme.accent, in: Circle())
                    .scaleEffect(badgeIn ? 1 : 0.3)
                    .opacity(badgeIn ? 1 : 0)

                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(badgeIn ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { badgeIn = true }
        }
    }
}

/// A one-shot fall of confetti pieces in the app's palette.
private struct ConfettiBurst: View {
    private let colors: [Color] = [Theme.accent, Theme.win, Theme.loss, .white]
    private let pieces = 40

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<pieces, id: \.self) { i in
                    ConfettiPiece(
                        color: colors[i % colors.count],
                        startX: .random(in: 0...geo.size.width),
                        endY: geo.size.height + 40,
                        delay: Double.random(in: 0...0.25),
                        drift: .random(in: -50...50)
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct ConfettiPiece: View {
    let color: Color
    let startX: CGFloat
    let endY: CGFloat
    let delay: Double
    let drift: CGFloat

    @State private var fall = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 7, height: 11)
            .rotationEffect(.degrees(fall ? Double.random(in: 180...540) : 0))
            .position(x: startX + (fall ? drift : 0), y: fall ? endY : -40)
            .opacity(fall ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: 1.1).delay(delay)) { fall = true }
            }
    }
}
