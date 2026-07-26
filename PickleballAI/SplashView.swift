import SwiftUI

/// Cold-launch splash: the ball serves into the paddle, the impact throws off
/// the wordmark. Native launch screens can't animate, so this plays as a
/// SwiftUI overlay for one beat immediately after `RootView` appears.
struct SplashView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paddleOpacity: Double = 0
    @State private var paddleScale: CGFloat = 0.92
    @State private var paddleSquash: CGFloat = 1
    @State private var ballOffset = CGSize(width: 90, height: -110)
    @State private var ballOpacity: Double = 0
    @State private var ballScale: CGFloat = 0.8
    @State private var ballSpin: Double = 0
    @State private var shockOpacity: Double = 0
    @State private var shockScale: CGFloat = 0.7
    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkScale: CGFloat = 0.96
    @State private var rootOpacity: Double = 1

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 26) {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 130, height: 130)
                        .scaleEffect(shockScale)
                        .opacity(shockOpacity)
                        .blur(radius: 4)

                    PaddleShape()
                        .fill(Theme.accent)
                        .overlay(
                            PaddleFaceShape()
                                .stroke(Theme.background, lineWidth: 9)
                        )
                        .frame(width: 92, height: 148)
                        .scaleEffect(x: paddleSquash, y: 2 - paddleSquash)
                        .scaleEffect(paddleScale)
                        .opacity(paddleOpacity)

                    BallView()
                        .frame(width: 42, height: 42)
                        .scaleEffect(ballScale)
                        .rotationEffect(.degrees(ballSpin))
                        .offset(ballOffset)
                        .opacity(ballOpacity)
                }
                .frame(height: 170)

                Text("piclr")
                    .font(Theme.wordmark(38))
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(wordmarkOpacity)
                    .scaleEffect(wordmarkScale)
            }
        }
        .opacity(rootOpacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("piclr")
        .task { await runSequence() }
    }

    private func runSequence() async {
        if reduceMotion {
            await runReducedMotionSequence()
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            paddleOpacity = 1
            paddleScale = 1
        }
        guard await pause(nanoseconds: 100_000_000) else { return }

        withAnimation(.easeIn(duration: 0.19)) {
            ballOffset = .zero
            ballOpacity = 1
            ballScale = 1
            ballSpin = 140
        }
        guard await pause(nanoseconds: 190_000_000) else { return }

        withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) {
            paddleSquash = 0.9
        }
        withAnimation(.easeOut(duration: 0.1)) {
            shockOpacity = 0.42
            shockScale = 1.2
        }
        guard await pause(nanoseconds: 70_000_000) else { return }

        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            paddleSquash = 1
        }
        withAnimation(.easeOut(duration: 0.12)) {
            shockOpacity = 0
        }
        withAnimation(.easeIn(duration: 0.15)) {
            ballOffset = CGSize(width: -110, height: 130)
            ballOpacity = 0
            ballScale = 0.7
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            wordmarkOpacity = 1
            wordmarkScale = 1
        }

        guard await pause(nanoseconds: 280_000_000) else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            rootOpacity = 0
        }
        guard await pause(nanoseconds: 140_000_000) else { return }
        onFinished()
    }

    private func runReducedMotionSequence() async {
        paddleOpacity = 1
        paddleScale = 1
        ballOpacity = 0
        wordmarkOpacity = 1
        wordmarkScale = 1

        guard await pause(nanoseconds: 250_000_000) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            rootOpacity = 0
        }
        guard await pause(nanoseconds: 120_000_000) else { return }
        onFinished()
    }

    private func pause(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return true
        } catch {
            return false
        }
    }
}

/// Paddle head + tapered handle, matching the app icon's proportions.
private struct PaddleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let headHeight = rect.height * 0.7
        let headRect = CGRect(x: 0, y: 0, width: rect.width, height: headHeight)
        path.addPath(Path(roundedRect: headRect, cornerSize: CGSize(width: rect.width / 2, height: rect.width / 2)))

        let handleWidth = rect.width * 0.3
        let handleRect = CGRect(
            x: (rect.width - handleWidth) / 2,
            y: headHeight - 12,
            width: handleWidth,
            height: rect.height - headHeight + 12
        )
        path.addPath(Path(roundedRect: handleRect, cornerSize: CGSize(width: handleWidth / 2, height: handleWidth / 2)))
        return path
    }
}

/// The rounded outline stamped into the paddle head.
private struct PaddleFaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let dx = rect.width * 0.24
        let dy = rect.height * 0.16
        let faceRect = rect.insetBy(dx: dx, dy: dy).offsetBy(dx: 0, dy: -rect.height * 0.02)
        return Path(roundedRect: faceRect, cornerSize: CGSize(width: faceRect.width / 2, height: faceRect.width / 2))
    }
}

/// Ball with the icon's 7-dot flower pattern of holes.
private struct BallView: View {
    var body: some View {
        GeometryReader { geo in
            let diameter = geo.size.width
            ZStack {
                Circle().fill(Theme.accent)
                ForEach(0..<7, id: \.self) { index in
                    Circle()
                        .fill(Theme.background)
                        .frame(width: diameter * 0.15, height: diameter * 0.15)
                        .offset(dotOffset(index, radius: diameter * 0.24))
                }
            }
        }
    }

    private func dotOffset(_ index: Int, radius: CGFloat) -> CGSize {
        guard index > 0 else { return .zero }
        let angle: Double = Double(index - 1) / 6.0 * 2 * .pi
        let x = Foundation.cos(angle)
        let y = Foundation.sin(angle)
        return CGSize(width: radius * x, height: radius * y)
    }
}

#Preview {
    SplashView(onFinished: {})
}
