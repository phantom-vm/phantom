import SwiftUI

/// The GitLab runner's configuration, editable from the Integration pane.
///
/// Two operations wear one form, because to the reader they are one thing —
/// "what is this runner set to":
///
/// - **Not registered yet** — every field is required and applying registers.
/// - **Registered** — `concurrent` is a config edit that the registration
///   survives, while a new URL or token can only be applied by registering
///   again, which throws the current registration away. The button renames
///   itself and the sheet says so before that happens.
struct GitLabRunnerConfigSheet: View {
    @Bindable var vm: VMManager

    @Environment(\.dismiss) private var dismiss

    @State private var url: String
    @State private var token: String
    @State private var concurrent: Int
    /// The token is prefilled so a URL change doesn't cost one, but it is a
    /// credential on a pane that gets screen-shared — masked until asked for.
    @State private var revealToken = false
    @State private var errorMessage: String?

    /// What the file said when the sheet opened, to tell an edit from a
    /// retyping of the same value.
    private let original: GitLabRunnerManager.Configuration?

    init(vm: VMManager) {
        self.vm = vm
        let current = vm.gitlabRunnerManager.currentConfiguration()
        self.original = current
        _url = State(initialValue: current?.url ?? "https://gitlab.com")
        _token = State(initialValue: current?.token ?? "")
        _concurrent = State(initialValue: current?.concurrent ?? 1)
    }

    private var runner: GitLabRunnerManager { vm.gitlabRunnerManager }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespaces) }

    /// Whether applying means registering again rather than editing a file.
    /// Only the two `[[runners]]` values GitLab itself knows about count.
    private var reregisters: Bool {
        guard let original else { return true }
        return trimmedURL != original.url || trimmedToken != original.token
    }

    private var hasChanges: Bool {
        guard let original else { return true }
        return reregisters || concurrent != original.concurrent
    }

    private var validationError: String? {
        if trimmedURL.isEmpty { return "A GitLab URL is required." }
        guard let parsed = URL(string: trimmedURL), parsed.scheme == "https" || parsed.scheme == "http",
            parsed.host != nil
        else {
            return "The URL should look like https://gitlab.com."
        }
        if trimmedToken.isEmpty { return "A runner authentication token is required." }
        return nil
    }

    /// Registering writes the CLI's path into the executor config, so a runner
    /// cannot be registered from the GUI on a Mac that has no CLI installed —
    /// every job would invoke a binary that isn't there.
    private var cliPath: String? { runner.resolvedCLIPath() }

    private var blockedReason: String? {
        switch runner.state {
        case .downloading: return "The runner binary is still downloading."
        case .registering: return "A registration is already running."
        default: break
        }
        if reregisters && cliPath == nil {
            return "The phantom CLI isn't installed — every job runs it, so registering needs it on disk."
        }
        return nil
    }

    private var actionTitle: String {
        if original == nil { return "Register" }
        return reregisters ? "Re-register" : "Apply"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(original == nil ? "Register GitLab Runner" : "GitLab Runner Configuration")
                .font(.headline)
                .padding(20)

            Divider()

            form

            Divider()

            HStack {
                if let message = errorMessage ?? blockedReason {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil || blockedReason != nil || !hasChanges)
            }
            .padding(20)
        }
        .frame(width: 480)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                TextField("GitLab URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                // Spelled out rather than left to the field's own label, so the
                // reveal button can sit *inside* the value column: leading the
                // field, not trailing it, which is what keeps this field's right
                // edge flush with the URL field above it.
                LabeledContent("Token") {
                    HStack(spacing: 6) {
                        Button {
                            revealToken.toggle()
                        } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealToken ? "Hide the token" : "Show the token")

                        Group {
                            if revealToken {
                                TextField("Token", text: $token)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Token", text: $token)
                            }
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    }
                }

                Text("Create the token in GitLab under Settings → CI/CD → Runners. It is stored in plain text in config.toml either way — hiding it here only keeps it off a shared screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                // The value already in the file is shown as it is rather than
                // clamped behind the user's back; the stepper just won't climb
                // past the ceiling.
                Stepper(
                    "Concurrent jobs: \(concurrent)",
                    value: $concurrent,
                    in: 1...GitLabRunnerManager.maxConcurrent
                )
                Text("Each job gets its own VM, and Virtualization.framework runs at most two macOS VMs at a time — so two is the ceiling, whatever the runner would accept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let validationError {
                Section {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if hasChanges {
                Section {
                    // Both of these are said before they happen, because nothing
                    // else on screen would show that applying costs a
                    // registration, or that it interrupts work in progress.
                    if original != nil && reregisters {
                        note(
                            "Changing the URL or token registers again from scratch. The current registration is discarded, GitLab gets a new runner, and the old one stays listed there until you remove it.",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    if runner.isRunning {
                        note(
                            "The runner reads its config at startup, so applying restarts it. A job running right now would be interrupted.",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func apply() {
        guard validationError == nil, blockedReason == nil else { return }

        // A concurrency-only change is a line in a file and a bounce of the
        // process: fast enough to report failure in the sheet that asked for it.
        if !reregisters {
            do {
                try runner.setConcurrent(concurrent)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            dismiss()
            return
        }

        guard let cliPath else { return }
        let url = trimmedURL
        let token = trimmedToken
        let concurrent = concurrent

        // Registering downloads a binary on first run and talks to GitLab, so it
        // outlives the sheet. Its progress and its failures are the runner's
        // state, which the Info tab behind this sheet is already showing.
        Task {
            try? await runner.setup(url: url, token: token, cliPath: cliPath, concurrent: concurrent)
        }
        dismiss()
    }
}
