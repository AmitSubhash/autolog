import SwiftUI

/// First-run onboarding view that guides users through granting
/// permissions and configuring their LLM provider.
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    var onComplete: () -> Void

    enum Step { case permissions, llmSetup }

    @State private var step: Step = .permissions

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .permissions:
                permissionsStep
            case .llmSetup:
                llmSetupStep
            }
        }
        .padding(32)
        .frame(width: 520)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Welcome to AutoLog")
                    .font(.title.bold())

                Text("AutoLog needs a few permissions to capture your screen activity and enrich your AI prompts with context.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Divider()

            VStack(spacing: 16) {
                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Read focused window titles and app information.",
                    isGranted: permissionManager.accessibilityGranted,
                    onRequest: { permissionManager.requestAccessibility() },
                    onOpenSettings: { permissionManager.openAccessibilitySettings() }
                )
            }

            Divider()

            HStack(spacing: 12) {
                Button("Refresh Status") {
                    permissionManager.refreshStatus()
                }
                .buttonStyle(.bordered)

                Button("Next") {
                    step = .llmSetup
                }
                .buttonStyle(.borderedProminent)
            }

            if !permissionManager.allPermissionsGranted {
                Text("Permissions may show as not granted after toggling. If you've enabled them in System Settings, click Next to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Step 2: LLM Setup

    @State private var selectedProvider: SettingsView.LLMProvider = .proxy
    @AppStorage("llmEndpointURL") private var customEndpointURL: String = ""
    @State private var proxyURL: String = "http://127.0.0.1:11434/v1/chat/completions"
    @State private var apiKey: String = ""
    @State private var proxyTestResult: String?
    @State private var proxyTesting: Bool = false
    @State private var showApiKeySaved: Bool = false
    @State private var hasApiKey: Bool = false
    @State private var saveError: String?

    private var llmConfigured: Bool {
        switch selectedProvider {
        case .proxy:
            return !proxyURL.isEmpty
        case .openrouter:
            return hasApiKey
        }
    }

    private var llmSetupStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48))
                    .foregroundStyle(.purple)

                Text("LLM Provider")
                    .font(.title.bold())

                Text("AutoLog uses an LLM to summarize your screen activity. Choose how to connect.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Divider()

            Picker("Provider:", selection: $selectedProvider) {
                ForEach(SettingsView.LLMProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            if selectedProvider == .proxy {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Proxy URL", text: $proxyURL)
                            .textFieldStyle(.roundedBorder)

                        Button(proxyTesting ? "Testing..." : "Test") {
                            testProxy()
                        }
                        .disabled(proxyURL.isEmpty || proxyTesting)
                    }

                    Text("Run `claude -p` in a terminal to start the proxy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let result = proxyTestResult {
                        HStack {
                            Image(systemName: result.starts(with: "OK") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.starts(with: "OK") ? .green : .red)
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.starts(with: "OK") ? .green : .red)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField("OpenRouter API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        Button(showApiKeySaved ? "Saved!" : "Save") {
                            saveKey()
                        }
                        .disabled(apiKey.isEmpty)
                    }

                    if let error = saveError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if hasApiKey {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("API key is configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button("Back") {
                    step = .permissions
                }
                .buttonStyle(.bordered)

                Button("Finish Setup") {
                    applyProvider()
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!llmConfigured)
            }

            Text("You can change this later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            hasApiKey = OpenRouterClient.hasAPIKey()
        }
    }

    private func applyProvider() {
        switch selectedProvider {
        case .proxy:
            customEndpointURL = proxyURL
        case .openrouter:
            customEndpointURL = ""
        }
    }

    private func testProxy() {
        guard let url = URL(string: proxyURL) else {
            proxyTestResult = "Invalid URL"
            return
        }
        proxyTesting = true
        proxyTestResult = nil

        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 5
            let body: [String: Any] = [
                "model": "anthropic/claude-haiku-4-5",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                    proxyTestResult = "OK - proxy is reachable (HTTP \(http.statusCode))"
                } else {
                    proxyTestResult = "Unexpected response"
                }
            } catch {
                proxyTestResult = "Connection failed: \(error.localizedDescription)"
            }
            proxyTesting = false
        }
    }

    private func saveKey() {
        do {
            try OpenRouterClient.saveAPIKey(apiKey)
            hasApiKey = true
            showApiKeySaved = true
            saveError = nil
            apiKey = ""
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showApiKeySaved = false
            }
        } catch {
            saveError = "Failed to save API key: \(error.localizedDescription)"
        }
    }
}

/// A single permission row showing status and action buttons.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)

                    Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(isGranted ? .green : .red)
                        .font(.caption)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("Grant") { onRequest() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Settings") { onOpenSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 8)
    }
}
