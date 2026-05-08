import SwiftUI

enum OnboardingTarget: Hashable {
    case drag
    case split
    case theme
    case settings
    case pin
}

struct OnboardingStep {
    let target: OnboardingTarget
    let title: String
    let description: String
}

struct OnboardingCoachMarksView: View {
    @AppStorage(AppPreferences.languageKey) private var appLanguageRaw = AppPreferences.languageDefault
    let stepIndex: Int
    let steps: [OnboardingStep]
    let targetFrame: CGRect?
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    private let cardWidth: CGFloat = 300
    private let cardHeight: CGFloat = 180
    private var language: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .english }
    private func t(_ en: String, _ zh: String) -> String {
        language == .chinese ? zh : en
    }

    var body: some View {
        GeometryReader { geo in
            let fallbackFrame = CGRect(
                x: geo.size.width * 0.5 - 20,
                y: geo.size.height * 0.5 - 20,
                width: 40,
                height: 40
            )
            let frame = targetFrame ?? fallbackFrame
            let placeAbove = frame.midY > geo.size.height * 0.46

            let unclampedCardX = frame.midX - cardWidth / 2
            let cardX = min(max(16, unclampedCardX), geo.size.width - cardWidth - 16)
            let cardY: CGFloat = placeAbove
                ? max(16, frame.minY - cardHeight - 18)
                : min(geo.size.height - cardHeight - 16, frame.maxY + 18)
            let arrowX = min(max(frame.midX, cardX + 24), cardX + cardWidth - 24)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                    .frame(width: frame.width + 8, height: frame.height + 8)
                    .position(x: frame.midX, y: frame.midY)

                coachCard
                    .frame(width: cardWidth, height: cardHeight)
                    .position(x: cardX + cardWidth / 2, y: cardY + cardHeight / 2)

                pointerTriangle(upward: placeAbove)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .frame(width: 16, height: 10)
                    .position(
                        x: arrowX,
                        y: placeAbove ? cardY + cardHeight + 5 : cardY - 5
                    )
            }
        }
    }

    private var coachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Quick Tour", "快速引导"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Text(steps[stepIndex].title)
                .font(.system(size: 16, weight: .bold))

            Text(steps[stepIndex].description)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            HStack {
                Text("\(stepIndex + 1) / \(steps.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                Button(t("Skip", "跳过")) { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Button(t("Back", "上一步")) { onBack() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .disabled(stepIndex == 0)

                Button(stepIndex == steps.count - 1 ? t("Done", "完成") : t("Next", "下一步")) { onNext() }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    private func pointerTriangle(upward: Bool) -> Path {
        Path { path in
            if upward {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 16, y: 0))
                path.addLine(to: CGPoint(x: 8, y: 10))
                path.closeSubpath()
            } else {
                path.move(to: CGPoint(x: 8, y: 0))
                path.addLine(to: CGPoint(x: 16, y: 10))
                path.addLine(to: CGPoint(x: 0, y: 10))
                path.closeSubpath()
            }
        }
    }
}

struct OnboardingTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [OnboardingTarget: CGRect] = [:]
    static func reduce(value: inout [OnboardingTarget: CGRect], nextValue: () -> [OnboardingTarget: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func captureOnboardingTarget(_ target: OnboardingTarget) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: OnboardingTargetFramePreferenceKey.self,
                    value: [target: geo.frame(in: .named("onboardingSpace"))]
                )
            }
        )
    }
}
