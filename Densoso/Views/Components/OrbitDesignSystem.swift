import SwiftUI

enum OrbitPalette {
    static let gold = Color("OrbitGold")
    static let blue = Color("OrbitBlue")
    static let coral = Color("OrbitCoral")
    static let green = Color("OrbitGreen")

    static let surface = Color(.secondarySystemBackground).opacity(0.82)
    static let elevatedSurface = Color(.tertiarySystemBackground).opacity(0.92)
    static let hairline = Color(.separator).opacity(0.72)
}
struct OrbitBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let diameter = max(proxy.size.width * 1.15, 420)

            ZStack {
                Color(.systemBackground)

                RadialGradient(
                    colors: [Color.white.opacity(0.055), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: diameter * 0.62
                )

                Circle()
                    .stroke(OrbitPalette.hairline.opacity(0.54), lineWidth: 0.6)
                    .frame(width: diameter, height: diameter)
                    .offset(x: diameter * 0.28, y: -diameter * 0.43)

                Circle()
                    .stroke(OrbitPalette.hairline.opacity(0.36), lineWidth: 0.6)
                    .frame(width: diameter * 0.48, height: diameter * 0.48)
                    .offset(x: diameter * 0.08, y: -diameter * 0.35)

                Circle()
                    .stroke(OrbitPalette.hairline.opacity(0.28), lineWidth: 0.6)
                    .frame(width: diameter * 0.74, height: diameter * 0.74)
                    .offset(x: -diameter * 0.6, y: diameter * 0.56)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct OrbitPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            OrbitBackground()
            content()
        }
        .preferredColorScheme(.dark)
    }
}

struct OrbitScreenHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String?

    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.largeTitle.weight(.bold))
                .fontWidth(.condensed)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct OrbitStatusBadge: View {
    enum Tone {
        case neutral
        case gold
        case blue
        case success
        case danger

        var color: Color {
            switch self {
            case .neutral: .secondary
            case .gold: OrbitPalette.gold
            case .blue: OrbitPalette.blue
            case .success: OrbitPalette.green
            case .danger: OrbitPalette.coral
            }
        }
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tone.color.opacity(0.28), lineWidth: 0.5))
    }
}

struct OrbitMetric: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct OrbitCardModifier: ViewModifier {
    let emphasized: Bool

    func body(content: Content) -> some View {
        content
            .padding()
            .background(emphasized ? OrbitPalette.elevatedSurface : OrbitPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(OrbitPalette.hairline, lineWidth: 0.6)
            }
    }
}

extension View {
    func orbitCard(emphasized: Bool = false) -> some View {
        modifier(OrbitCardModifier(emphasized: emphasized))
    }

    func orbitScrollBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}
