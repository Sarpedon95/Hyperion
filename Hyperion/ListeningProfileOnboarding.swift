import SwiftUI

// MARK: - Listening Profile Onboarding

/// 3-step sheet shown on first launch (or via Settings → Retune Profile).
/// Maps context + taste + genre to a built-in Orpheus DSP preset.
struct ListeningProfileOnboarding: View {

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var context: ListeningContext? = nil
    @State private var taste: TasteProfile? = nil
    @State private var genre: PrimaryGenre? = nil

    enum ListeningContext: String, CaseIterable, Identifiable {
        case headphones = "Headphones"
        case speakers   = "Speakers"
        case carPlay    = "CarPlay"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .headphones: return "headphones"
            case .speakers:   return "hifispeaker.2"
            case .carPlay:    return "car"
            }
        }
        var description: String {
            switch self {
            case .headphones: return "In-ear or over-ear listening"
            case .speakers:   return "Room stereo or bookshelf speakers"
            case .carPlay:    return "In the car via Apple CarPlay"
            }
        }
    }

    enum TasteProfile: String, CaseIterable, Identifiable {
        case flat       = "Reference Flat"
        case warm       = "Warm"
        case analytical = "Analytical"
        case bass       = "Bass Boost"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .flat:       return "waveform.path"
            case .warm:       return "sun.max"
            case .analytical: return "chart.xyaxis.line"
            case .bass:       return "speaker.wave.3"
            }
        }
        var description: String {
            switch self {
            case .flat:       return "Neutral, accurate reproduction"
            case .warm:       return "Gentle low-mid lift, smooth highs"
            case .analytical: return "Extended highs, precise imaging"
            case .bass:       return "Enhanced sub-bass and punch"
            }
        }
        var eqGains: [Float] {
            switch self {
            case .flat:       return Array(repeating: 0, count: 10)
            case .warm:       return [2, 2, 1.5, 1, 0.5, 0, 0, -0.5, -1, -1.5]
            case .analytical: return [-0.5, -0.5, 0, 0, 0, 0.5, 1, 1.5, 2, 2.5]
            case .bass:       return [4, 3.5, 2, 1, 0, 0, 0, 0, 0, 0]
            }
        }
    }

    enum PrimaryGenre: String, CaseIterable, Identifiable {
        case classical = "Classical"
        case jazz      = "Jazz"
        case pop       = "Pop / Rock"
        case mixed     = "Mixed"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .classical: return "music.quarternote.3"
            case .jazz:      return "guitars"
            case .pop:       return "music.mic"
            case .mixed:     return "shuffle"
            }
        }
        var mixSeedWeight: Double {
            switch self {
            case .classical: return 0.7
            case .jazz:      return 0.6
            case .pop:       return 0.5
            case .mixed:     return 0.33
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i <= step ? Color.roonAccent : Color.roonBorder)
                            .frame(height: 4)
                            .animation(.easeInOut, value: step)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 8)

                TabView(selection: $step) {
                    contextStep.tag(0)
                    tasteStep.tag(1)
                    genreStep.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: step)
            }
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        applyProfile()
                        dismiss()
                    }
                    .foregroundColor(.roonSecondary)
                }
            }
        }
    }

    // MARK: - Steps

    private var contextStep: some View {
        OnboardingStep(
            title: "How do you listen?",
            subtitle: "Choose your primary listening setup. You can always change this in Settings.",
            step: 1, total: 3
        ) {
            ForEach(ListeningContext.allCases) { ctx in
                OnboardingOptionRow(
                    title: ctx.rawValue,
                    subtitle: ctx.description,
                    icon: ctx.icon,
                    selected: context == ctx
                ) {
                    Haptics.light()
                    context = ctx
                    withAnimation { step = 1 }
                }
            }
        }
    }

    private var tasteStep: some View {
        OnboardingStep(
            title: "Choose your sound",
            subtitle: "Pick a tonal preference. This sets your Orpheus EQ starting point.",
            step: 2, total: 3
        ) {
            ForEach(TasteProfile.allCases) { t in
                OnboardingOptionRow(
                    title: t.rawValue,
                    subtitle: t.description,
                    icon: t.icon,
                    selected: taste == t
                ) {
                    Haptics.light()
                    taste = t
                    withAnimation { step = 2 }
                }
            }
        }
    }

    private var genreStep: some View {
        OnboardingStep(
            title: "What do you mostly play?",
            subtitle: "Tunes the smart queue to favour your preferred repertoire.",
            step: 3, total: 3
        ) {
            ForEach(PrimaryGenre.allCases) { g in
                OnboardingOptionRow(
                    title: g.rawValue,
                    subtitle: nil,
                    icon: g.icon,
                    selected: genre == g
                ) {
                    Haptics.light()
                    genre = g
                }
            }

            Button {
                applyProfile()
                dismiss()
            } label: {
                Text("Get Started")
                    .font(.roonBody(16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(genre != nil ? Color.roonAccent : Color.roonTertiary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(genre == nil)
            .padding(.top, 8)
        }
    }

    // MARK: - Apply

    private func applyProfile() {
        let dsp = OrpheusDSPEngine.shared

        // Apply EQ from taste profile
        if let taste {
            let gains = taste.eqGains
            let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
            dsp.mainEQBands = zip(freqs, gains).map { freq, gain in
                OrpheusEQBand(filterType: .peak, frequency: freq, gain: gain, bandwidth: 1, isActive: true)
            }
            dsp.applyMainEQ()
        }

        // Persist context + genre for MixGenerator / other features
        UserDefaults.standard.set(context?.rawValue, forKey: "hyperion.profile.context")
        UserDefaults.standard.set(genre?.rawValue, forKey: "hyperion.profile.genre")
        UserDefaults.standard.set(genre?.mixSeedWeight, forKey: "hyperion.profile.mixSeedWeight")

        // Mark onboarding complete
        UserDefaults.standard.set(true, forKey: "hyperion.onboarding.complete")
    }
}

// MARK: - Sub-views

private struct OnboardingStep<Content: View>: View {
    let title: String
    let subtitle: String
    let step: Int
    let total: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step \(step) of \(total)")
                        .font(.roonBody(12, weight: .semibold))
                        .foregroundColor(.roonAccent)
                        .kerning(0.8)
                    Text(title)
                        .font(.roonTitle(26))
                        .foregroundColor(.roonPrimary)
                    Text(subtitle)
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                VStack(spacing: 10) {
                    content()
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 40)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase)
    }
}

private struct OnboardingOptionRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.roonAccent : Color.roonSurface)
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(selected ? .white : .roonSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.roonBody(15, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.roonAccent)
                }
            }
            .padding(14)
            .background(Color.roonSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.roonAccent : Color.roonBorder, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
