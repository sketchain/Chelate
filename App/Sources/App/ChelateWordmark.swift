import SwiftUI

/// Home screen title: 「Chelate²⁻」 in heavy SF Mono with the charge as a real superscript
/// (U+2212 minus), filled with a left-to-right gradient from the accent colour (orange) to pink.
///
/// A soft highlight sweeps across once (about 1 s) whenever the app is opened: on cold launch
/// and when it returns from the background. Skipped with Reduce Motion.
struct ChelateWordmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 34
    @State private var sweep = 0
    @State private var wasInBackground = false

    static let gradient = LinearGradient(
        colors: [Color.accentColor, Color.pink],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        wordmark
            .foregroundStyle(Self.gradient)
            .overlay {
                highlight
                    .mask(wordmark)
                    .allowsHitTesting(false)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Chelate"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home-title")
            .onAppear(perform: play)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasInBackground = true
                case .active where wasInBackground:
                    wasInBackground = false
                    play()
                default:
                    break
                }
            }
    }

    /// 「Chelate」 plus the superscript at about half size, baseline raised.
    private var wordmark: some View {
        var name = AttributedString("Chelate")
        name.font = .system(size: size, weight: .heavy, design: .monospaced)
        var charge = AttributedString("2\u{2212}")
        charge.font = .system(size: size * 0.5, weight: .heavy, design: .monospaced)
        charge.baselineOffset = size * 0.38
        return Text(name + charge)
            .lineLimit(1)
    }

    /// Band of light that travels from fully left of the text to fully right of it.
    private var highlight: some View {
        GeometryReader { proxy in
            let band = max(proxy.size.width * 0.4, 1)
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: sweep) { content, progress in
                content.offset(x: -band + progress * (proxy.size.width + band))
            } keyframes: { _ in
                CubicKeyframe(1, duration: 1.0)
            }
            .opacity(sweep == 0 ? 0 : 1)
        }
        .blendMode(.plusLighter)
    }

    private func play() {
        guard !reduceMotion else { return }
        sweep += 1
    }
}
