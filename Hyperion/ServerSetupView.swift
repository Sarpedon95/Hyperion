import SwiftUI

// MARK: - Server Setup

struct ServerSetupView: View {

    let onComplete: () -> Void
    let onBack: () -> Void

    @ObservedObject private var connection = ConnectionManager.shared
    @State private var serverAddress: String = ""
    @State private var webPort: String = "9000"
    @State private var streamPort: String = "3483"
    @State private var showAdvanced: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: Bool? = nil
    @State private var testMessage: String? = nil
    @State private var isDiscovering: Bool = false
    @FocusState private var focusField: SetupField?

    enum SetupField: Hashable {
        case address, webPort, streamPort, username, password
    }

    private static let accentBlue = Color(red: 0, green: 0.478, blue: 1.0)

    private let commonAddresses: [(display: String, value: String)] = [
        ("192.168.1.x:9000",   "http://192.168.1.100:9000"),
        ("10.0.0.x:9000",      "http://10.0.0.1:9000"),
        ("lyrion.local:9000",  "http://lyrion.local:9000"),
        ("100.x.x.x:9000",    "http://100.64.0.1:9000"),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                GeometryReader { geo in
                    progressBar
                        .padding(.horizontal, 20)
                        .padding(.top, geo.safeAreaInsets.top + 16)
                }
                .frame(height: 60)

                ScrollView {
                    VStack(spacing: 20) {
                        discoverButton
                        addressField
                        HStack(spacing: 12) {
                            portField(label: "Web Port",    placeholder: "9000", binding: $webPort,    field: .webPort)
                            portField(label: "Stream Port", placeholder: "3483", binding: $streamPort, field: .streamPort)
                        }
                        advancedSection
                        commonAddressSection
                        if let msg = testMessage {
                            testResultBanner(message: msg, success: testResult == true)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 120)
                }

                bottomBar
            }
        }
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            if !connection.localURL.isEmpty {
                serverAddress = connection.localURL
            }
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(Self.accentBlue)
                    .frame(width: geo.size.width * 0.5, height: 4)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Discover

    private var discoverButton: some View {
        Button { discover() } label: {
            HStack(spacing: 10) {
                if isDiscovering {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: "wifi")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(isDiscovering ? "Discovering..." : "Discover Server")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Self.accentBlue)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ScaleOnPressStyle())
        .disabled(isDiscovering)
    }

    // MARK: - Address field

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Address")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.55))

            TextField("192.168.1.x or lyrion.local", text: $serverAddress)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($focusField, equals: .address)
        }
    }

    // MARK: - Port field

    private func portField(
        label: String,
        placeholder: String,
        binding: Binding<String>,
        field: SetupField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.55))

            TextField(placeholder, text: binding)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .keyboardType(.numberPad)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($focusField, equals: field)
        }
    }

    // MARK: - Advanced section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced: Authentication (Optional)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(white: 0.55))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.35))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: showAdvanced)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(spacing: 12) {
                    credentialField(label: "Username", placeholder: "Optional", binding: $username, field: .username, secure: false)
                    credentialField(label: "Password", placeholder: "Optional", binding: $password, field: .password, secure: true)
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func credentialField(
        label: String,
        placeholder: String,
        binding: Binding<String>,
        field: SetupField,
        secure: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.45))

            Group {
                if secure {
                    SecureField(placeholder, text: binding)
                } else {
                    TextField(placeholder, text: binding)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .font(.system(size: 15))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .focused($focusField, equals: field)
        }
    }

    // MARK: - Common addresses

    private var commonAddressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Common LMS Addresses")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.45))

            let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(commonAddresses, id: \.display) { item in
                    Button {
                        Haptics.light()
                        serverAddress = item.value
                    } label: {
                        Text(item.display)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Self.accentBlue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(white: 0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(ScaleOnPressStyle())
                }
            }
        }
    }

    // MARK: - Test result banner

    private func testResultBanner(message: String, success: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(success ? .green : Color(red: 1, green: 0.27, blue: 0.23))
                .font(.system(size: 16))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Color.white.opacity(0.08).frame(height: 0.5)

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("Back")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(white: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ScaleOnPressStyle())

                Button { testConnection() } label: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        }
                        Text(isTesting ? "Connecting..." : "Test Connection")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        testResult == true
                            ? Color(red: 0.15, green: 0.7, blue: 0.35)
                            : Self.accentBlue
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ScaleOnPressStyle())
                .disabled(isTesting || serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .background(Color.black)
        }
    }

    // MARK: - Actions

    private func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        testMessage = nil
        testResult = nil

        Task { @MainActor in
            defer { isDiscovering = false }
            let candidates = [
                "http://lyrion.local:9000",
                "http://squeezebox.local:9000",
                "http://logitech.local:9000",
            ]
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let result = await ConnectionManager.probeBestServer(candidate, mode: .local)
                if result.isSuccess {
                    serverAddress = candidate
                    Haptics.medium()
                    return
                }
            }
            testMessage = "No server found automatically. Enter the address manually."
            testResult = false
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        let raw = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        isTesting = true
        testResult = nil
        testMessage = nil

        Task { @MainActor in
            defer { isTesting = false }
            let result = await ConnectionManager.probeBestServer(raw, mode: .local)
            testResult = result.isSuccess
            testMessage = result.summary

            if result.isSuccess {
                Haptics.medium()
                saveAndProceed(url: result.url)
            } else {
                Haptics.light()
            }
        }
    }

    private func saveAndProceed(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // AUDIT-FIX #4 — persist credentials to Keychain, not embedded in the URL.
        HyperionURLAuth.saveCredentials(username: username, password: password)
        connection.localURL = trimmed
        connection.saveSettings()
        LibraryViewModel.shared.clearCache()
        ArtworkCache.shared.clear()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            onComplete()
        }
    }
}

// MARK: - Press scale button style (shared)

struct ScaleOnPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
