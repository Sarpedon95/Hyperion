import SwiftUI

// MARK: - Onboarding flow coordinator

struct HyperionOnboardingFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int = 0

    var body: some View {
        Group {
            if step == 0 {
                WelcomeView { withAnimation(.easeInOut(duration: 0.3)) { step = 1 } }
            } else {
                ServerSetupView(
                    onComplete: {
                        UserDefaults.standard.set(true, forKey: "hyperion.onboarding.complete")
                        dismiss()
                    },
                    onBack: { withAnimation(.easeInOut(duration: 0.3)) { step = 0 } }
                )
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Welcome screen

struct WelcomeView: View {
    let onGetStarted: () -> Void

    private static let accentBlue = Color(red: 0, green: 0.478, blue: 1.0)

    private struct Feature {
        let icon: String
        let title: String
        let subtitle: String
    }

    private let features: [Feature] = [
        Feature(icon: "server.rack",    title: "Stream from LMS",       subtitle: "Connect to your music server"),
        Feature(icon: "waveform",       title: "High Quality Audio",    subtitle: "FLAC, AAC, and MP3 support"),
        Feature(icon: "lock.display",   title: "Background Playback",   subtitle: "Control from lock screen"),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // Logo
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(white: 0.11))
                            .frame(width: 88, height: 88)
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    // App name
                    Text("Hyperion")
                        .font(.roonBody(38, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 22)

                    // Subtitle
                    Text("Your music, anywhere.\nStream from your Lyrion Music Server.")
                        .font(.roonBody(16))
                        .foregroundColor(Color(white: 0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, 10)
                        .padding(.horizontal, 36)

                    Spacer().frame(height: 52)

                    // Feature rows
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(features, id: \.title) { feature in
                            HStack(spacing: 18) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(Self.accentBlue)
                                    .frame(width: 30)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                        .font(.roonBody(15, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(feature.subtitle)
                                        .font(.roonBody(13))
                                        .foregroundColor(Color(white: 0.5))
                                }

                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer()

                    // Get Started button
                    Button(action: onGetStarted) {
                        Text("Get Started")
                            .font(.roonBody(17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Self.accentBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(ScaleOnPressStyle(scale: 0.97))
                    .padding(.horizontal, 20)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom + 16, 36))
                }
            }
        }
        .ignoresSafeArea()
    }
}
