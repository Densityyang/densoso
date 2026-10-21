import SwiftUI

/// A small, native ambient treatment for the live listening state.
/// Its motion pauses when listening stops or Reduce Motion is enabled.
struct VoiceActivityOrb: View {
    let symbol: String
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.055, paused: !isActive || reduceMotion)) { timeline in
            let phase = isActive && !reduceMotion
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [OrbitPalette.gold, OrbitPalette.coral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.92), .white.opacity(0.04), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 10
                        )
                    )
                    .frame(width: 17, height: 17)
                    .offset(
                        x: CGFloat(cos(phase * 0.62) * 2.4),
                        y: CGFloat(sin(phase * 0.48) * 2.1)
                    )

                Ellipse()
                    .fill(OrbitPalette.coral.opacity(0.78))
                    .frame(width: 13, height: 8)
                    .blur(radius: 3)
                    .offset(
                        x: CGFloat(sin(phase * 0.43) * 2.3),
                        y: CGFloat(cos(phase * 0.57) * 2.5)
                    )

                Circle()
                    .strokeBorder(.white.opacity(0.42), lineWidth: 0.7)

                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white)
            }
            .clipShape(Circle())
            .frame(width: 24, height: 24)
        }
        .accessibilityHidden(true)
    }
}
