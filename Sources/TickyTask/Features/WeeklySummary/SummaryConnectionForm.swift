import SwiftUI

/// How Codex connects for Weekly Summary: the user's ChatGPT account, the Codex
/// CLI's own configuration, or a self-hosted model server. Shared by the
/// sheet's Connection popover and Settings › AI.
struct SummaryConnectionForm: View {
    /// Called after any change, so the owner can reload models.
    var onChange: () -> Void = {}
    var accountStatus: () async -> SummaryAccountStatus
    var signIn: () async throws -> Void

    @State private var kind = SummaryPreferences().connectionKind
    @State private var server = SummaryPreferences().localServer
    @State private var baseURL = SummaryPreferences().localBaseURL
    @State private var apiKey = SummaryKeychain().read() ?? ""
    @State private var status: SummaryAccountStatus = .unknown
    @State private var isSigningIn = false
    @State private var signInError: String?

    private var preferences: SummaryPreferences { SummaryPreferences() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Connect Codex using", selection: $kind) {
                ForEach(SummaryPreferences.ConnectionKind.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("summary-connection-kind")
            .onChange(of: kind) { _, value in
                preferences.connectionKind = value
                onChange()
                Task { await loadStatus() }
            }

            switch kind {
            case .chatGPTAccount:
                accountSection
            case .cliConfiguration:
                Text("Uses the provider and sign-in in your `~/.codex/config.toml` (for example a company gateway).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .local:
                localSection
            }
        }
        .task { await loadStatus() }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch status {
                case .signedIn(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .signedOut:
                    Label("Not signed in", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .unknown:
                    Label("Sign-in status unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                if isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(status == .signedOut ? "Sign in…" : "Sign in again…") { Task { await runSignIn() } }
                        .accessibilityIdentifier("summary-sign-in")
                }
            }
            .font(.callout)
            Text("Uses your own ChatGPT sign-in for Codex (`codex login`), ignoring any custom provider in your Codex configuration.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let signInError {
                Text(signInError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Server", selection: $server) {
                ForEach(SummaryLocalServer.allCases) { Text($0.displayName).tag($0) }
            }
            .accessibilityIdentifier("summary-local-server")
            .onChange(of: server) { _, value in
                preferences.localServer = value
                onChange()
            }
            LabeledContent("Base URL") {
                TextField(server.defaultBaseURL.isEmpty ? "http://localhost:8000/v1" : server.defaultBaseURL, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("summary-local-url")
                    .onSubmit(saveLocal)
                    .onChange(of: baseURL) { _, _ in saveLocal() }
            }
            LabeledContent("API key") {
                SecureField("Optional", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("summary-local-key")
                    .onSubmit(saveKey)
                    .onChange(of: apiKey) { _, _ in saveKey() }
            }
            Text(localHelp)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localHelp: String {
        switch server {
        case .ollama, .lmStudio:
            "Codex talks to \(server.displayName) with its built-in local provider. Leave the URL blank for \(server.defaultBaseURL). Pick a model in Weekly Summary — Refresh lists the server's models — or type its name. The API key is only needed if your server requires one; it's stored in your Keychain."
        case .openAICompatible:
            "Any server with an OpenAI-compatible Responses API (/v1/responses). Enter its base URL including /v1. The API key, if needed, is stored in your Keychain and passed to Codex through the environment, never on the command line."
        }
    }

    private func saveLocal() {
        preferences.localBaseURL = baseURL
        onChange()
    }

    private func saveKey() {
        SummaryKeychain().write(apiKey)
    }

    private func loadStatus() async {
        guard kind == .chatGPTAccount else { return }
        status = await accountStatus()
    }

    private func runSignIn() async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            try await signIn()
        } catch let failure as WeeklySummaryError {
            let presentation = SummaryErrorPresenter.present(failure, authSetup: .accountLogin)
            signInError = "\(presentation.title). \(presentation.message)"
        } catch {
            signInError = error.localizedDescription
        }
        status = await accountStatus()
        onChange()
    }
}

/// Edits the user's custom summary instructions (applied on top of the built-in
/// rules), with the built-in rules viewable read-only.
struct SummaryInstructionsEditor: View {
    @Binding var instructions: String
    @State private var showBuiltIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your instructions")
                .font(.headline)
            Text("Tell the summarizer about audience, tone, length, emphasis, or format — e.g. “Write for my manager, max 200 words, lead with risks.” They're added to the built-in rules, which always keep task notes as data and forbid inventing facts.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $instructions)
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier("summary-instructions")
            HStack {
                Text("\(instructions.count) / \(SummaryPrompt.customInstructionsLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(instructions.count > SummaryPrompt.customInstructionsLimit ? .orange : .secondary)
                Spacer()
                Button("Clear") { instructions = "" }
                    .disabled(instructions.isEmpty)
                    .accessibilityIdentifier("summary-instructions-clear")
            }
            DisclosureGroup("Built-in rules (always applied)", isExpanded: $showBuiltIn) {
                ScrollView {
                    Text(SummaryPrompt.instructions)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            .font(.callout)
        }
        .onChange(of: instructions) { _, value in
            if value.count > SummaryPrompt.customInstructionsLimit {
                instructions = String(value.prefix(SummaryPrompt.customInstructionsLimit))
            }
        }
    }
}
