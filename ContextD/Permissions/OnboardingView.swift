import SwiftUI

/// First-run onboarding view that guides users through granting
/// permissions and configuring their LLM provider.
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    var onComplete: () -> Void

    enum Step { case permissions, llmSetup }

    @State private var step: Step = .permissions
    @State private var didAutoRequestScreenRecording = false

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
                    icon: "display",
                    title: "Screen Recording",
                    description: "Allow AutoLog to capture your screen and build summaries.",
                    isGranted: permissionManager.screenRecordingGranted,
                    onRequest: { permissionManager.requestScreenRecording() },
                    onOpenSettings: { permissionManager.openScreenRecordingSettings() }
                )

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
                Text("If Screen Recording still does not register, make sure you launched the bundled app. In development, use `make run-bundle` or `make install-app`, not the raw executable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            guard !permissionManager.screenRecordingGranted, !didAutoRequestScreenRecording else {
                return
            }
            didAutoRequestScreenRecording = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 750_000_000)
                permissionManager.requestScreenRecording()
            }
        }
    }

    // MARK: - Step 2: LLM Setup

    @State private var selectedProvider: LLMProvider = .claude
    @AppStorage("llmProvider") private var llmProviderRawValue: String = LLMProvider.claude.rawValue
    @State private var claudeAvailable: Bool = false
    @State private var apiKey: String = ""
    @State private var showApiKeySaved: Bool = false
    @State private var hasApiKey: Bool = false
    @State private var saveError: String?

    private var llmConfigured: Bool {
        switch selectedProvider {
        case .claude:
            return claudeAvailable
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
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            if selectedProvider == .claude {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: claudeAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(claudeAvailable ? .green : .red)
                        Text(claudeAvailable ? "Claude CLI is available" : "Claude CLI not found")
                            .font(.caption)
                    }
                    Text("AutoLog can use your Claude Code session directly. No local proxy needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            claudeAvailable = ClaudeShellClient.isAvailable()
            hasApiKey = OpenRouterClient.hasAPIKey()
            selectedProvider = LLMProvider(rawValue: llmProviderRawValue) ?? .claude
        }
    }

    private func applyProvider() {
        llmProviderRawValue = selectedProvider.rawValue
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
