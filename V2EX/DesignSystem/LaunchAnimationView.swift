import SwiftUI
import UIKit

/// Continues seamlessly from the static launch screen, then reveals the app.
/// The geometry and colours mirror the layered app icon.
struct LaunchAnimationView: View {
    let onFinish: () -> Void

    @State private var threadProgress: CGFloat = 0
    @State private var highlightProgress: CGFloat = 0
    @State private var highlightOpacity = 0.0
    @State private var markScale: CGFloat = 1
    @State private var logoOffset: CGFloat = 0
    @State private var dotScale: CGFloat = 1
    @State private var haloProgress: CGFloat = 0
    @State private var haloActive = false
    @State private var wordmarkOpacity = 0.0
    @State private var wordmarkOffset: CGFloat = 116
    @State private var screenOpacity = 1.0
    @State private var screenScale: CGFloat = 1

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0A8F68), Color(hex: 0x004D3A)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            logo
                .offset(y: logoOffset)

            wordmark
                .offset(y: wordmarkOffset)
                .opacity(wordmarkOpacity)
        }
        .scaleEffect(screenScale)
        .opacity(screenOpacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("v2Explore, Way to Explore")
        .task { await play() }
    }

    private var logo: some View {
        ZStack {
            LaunchThreadLines()
                .trim(from: 0, to: threadProgress)
                .stroke(
                    Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

            LaunchVMark()
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round)
                )

            LaunchVMark()
                .trim(from: max(0, highlightProgress - 0.28), to: highlightProgress)
                .stroke(
                    Color.white.opacity(0.98),
                    style: StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Color.white.opacity(0.8), radius: 8)
                .opacity(highlightOpacity)

            if haloActive {
                Circle()
                    .stroke(Color(hex: 0xF2A93B).opacity(0.7), lineWidth: 2)
                    .frame(width: 20, height: 20)
                    .scaleEffect(0.7 + haloProgress * 1.55)
                    .opacity(Double(1 - haloProgress))
                    .offset(y: 34.4)
            }

            Circle()
                .fill(Color(hex: 0xF2A93B))
                .frame(width: 20, height: 20)
                .scaleEffect(dotScale)
                .offset(y: 34.4)
        }
        .frame(width: 160, height: 160)
        .scaleEffect(markScale)
    }

    private var wordmark: some View {
        VStack(spacing: 6) {
            Text("v2Explore")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Way to Explore")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.76))
        }
    }

    @MainActor
    private func play() async {
        if UIAccessibility.isReduceMotionEnabled {
            threadProgress = 1
            wordmarkOffset = 112
            wordmarkOpacity = 1

            await pause(milliseconds: 450)
            withAnimation(.easeOut(duration: 0.25)) { screenOpacity = 0 }
            await pause(milliseconds: 280)
            onFinish()
            return
        }

        // Let the first SwiftUI frame hold the exact static launch-screen mark
        // before adding motion, avoiding a visible hand-off jump.
        await pause(milliseconds: 160)

        withAnimation(.easeOut(duration: 0.72)) {
            threadProgress = 1
            highlightProgress = 1
            highlightOpacity = 1
            markScale = 1.035
        }

        await pause(milliseconds: 480)
        withAnimation(.easeOut(duration: 0.55)) {
            logoOffset = -30
            wordmarkOffset = 100
            wordmarkOpacity = 1
            markScale = 1
        }

        haloActive = true
        await Task.yield()
        withAnimation(.easeOut(duration: 0.7)) { haloProgress = 1 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.5)) { dotScale = 1.22 }

        await pause(milliseconds: 180)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { dotScale = 1 }

        await pause(milliseconds: 220)
        withAnimation(.easeOut(duration: 0.24)) { highlightOpacity = 0 }

        await pause(milliseconds: 980)
        withAnimation(.easeIn(duration: 0.38)) {
            screenScale = 1.055
            screenOpacity = 0
        }

        await pause(milliseconds: 420)
        onFinish()
    }

    private func pause(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

private struct LaunchVMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.28, y: rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.width * 0.50, y: rect.height * 0.715))
        path.addLine(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.28))
        return path
    }
}

private struct LaunchThreadLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rows: [(y: CGFloat, start: CGFloat, end: CGFloat)] = [
            (0.414, 0.209, 0.791),
            (0.500, 0.244, 0.756),
            (0.586, 0.287, 0.713)
        ]

        for row in rows {
            path.move(to: CGPoint(x: rect.width * row.start, y: rect.height * row.y))
            path.addLine(to: CGPoint(x: rect.width * row.end, y: rect.height * row.y))
        }
        return path
    }
}
