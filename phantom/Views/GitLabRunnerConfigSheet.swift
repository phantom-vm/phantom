import SwiftUI

/// The GitLab runner's configuration, editable from the Integration pane.
///
/// Three kinds of setting wear one form, because to the reader they are one
/// thing — "what is this runner set to" — and they cost different things to
/// apply, which the sheet says out loud rather than hiding:
///
/// - **Not registered yet** — every field is required and applying registers.
/// - **URL or token** — only applicable by registering again, which throws the
///   current registration away. The button renames itself to Re-register.
/// - **Concurrency** — a config edit the registration survives, but the runner
///   reads it at startup, so it is bounced.
/// - **Job VM size** — phantom's own setting, not gitlab-runner's. It decides
///   what the *next* job's VM is created with, so nothing is restarted.
struct GitLabRunnerConfigSheet: View {
    @Bindable var vm: VMManager

    @Environment(\.dismiss) private var dismiss

    @State private var url: String
    @State private var token: String
    @State private var concurrent: Int
    @State private var cpuCount: Int
    @State private var memoryGB: Int
    /// The token is prefilled so a URL change doesn't cost one, but it is a
    /// credential on a pane that gets screen-shared — masked until asked for.
    @State private var revealToken = false
    @State private var errorMessage: String?

    /// What the files said when the sheet opened, to tell an edit from a
    /// retyping of the same value.
    private let original: GitLabRunnerManager.Configuration?
    private let originalJobVM: VMSettings

    init(vm: VMManager) {
        self.vm = vm
        let current = vm.gitlabRunnerManager.currentConfiguration()
        let jobVM = vm.gitlabRunnerManager.jobVMSettings
        self.original = current
        self.originalJobVM = jobVM
        _url = State(initialValue: current?.url ?? "https://gitlab.com")
        _token = State(initialValue: current?.token ?? "")
        _concurrent = State(initialValue: current?.concurrent ?? 1)
        _cpuCount = State(initialValue: jobVM.cpuCount)
        _memoryGB = State(initialValue: Int(jobVM.memorySize / (1024 * 1024 * 1024)))
    }

    private var maxCPUCount: Int { VMSettings.maximumCPUCount }
    private var minMemoryGB: Int { max(1, Int(VMSettings.minimumMemorySize / (1024 * 1024 * 1024))) }
    private var maxMemoryGB: Int { Int(VMSettings.maximumMemorySize / (1024 * 1024 * 1024)) }

    private var jobVMSettings: VMSettings {
        VMSettings(cpuCount: cpuCount, memorySize: UInt64(memoryGB) * 1024 * 1024 * 1024)
    }

    private var jobVMChanged: Bool { jobVMSettings != originalJobVM }

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
        return reregisters || concurrent != original.concurrent || jobVMChanged
    }

    /// Whether applying stops the runner. Job VM size alone doesn't: it is read
    /// when the next job asks for a VM, not when the runner starts.
    private var restartsRunner: Bool {
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

            Section("Job VM") {
                // The same two sliders as CreateVMSheet, for the same reason: the
                // value is what matters, so it is labelled and kept beside the
                // track rather than left to be read off a handle position.
                LabeledContent("CPUs") {
                    HStack {
                        Slider(
                            value: cpuBinding,
                            in: Double(VMSettings.minimumCPUCount)...Double(maxCPUCount),
                            step: 1
                        ) {
                            EmptyView()
                        } minimumValueLabel: {
                            bound("\(VMSettings.minimumCPUCount)")
                        } maximumValueLabel: {
                            bound("\(maxCPUCount)")
                        }
                        Text("\(cpuCount)")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                LabeledContent("Memory") {
                    HStack {
                        // Unstepped, like CreateVMSheet's: a stepped track snaps
                        // to a grid anchored at the lower bound and puts the
                        // stated ceiling out of reach. The binding rounds.
                        Slider(value: memoryBinding, in: Double(minMemoryGB)...Double(maxMemoryGB)) {
                            EmptyView()
                        } minimumValueLabel: {
                            bound("\(minMemoryGB)")
                        } maximumValueLabel: {
                            bound("\(maxMemoryGB)")
                        }
                        Text("\(memoryGB) GB")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                Text("What every job's VM is created with. Two concurrent jobs take two of these at once, so this and the count above share one Mac between them.")
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
                    if restartsRunner && runner.isRunning {
                        note(
                            "The runner reads its config at startup, so applying restarts it. A job running right now would be interrupted.",
                            systemImage: "arrow.clockwise"
                        )
                    } else if jobVMChanged {
                        note(
                            "The runner keeps running: a VM's size is read when the next job asks for one, so a job already under way finishes at the old size.",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The ends of a track, so the handle reads as a proportion of what this Mac
    /// allows rather than a bare position.
    private func bound(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    /// Slider works in Double; the settings are integers. Rounding on the way
    /// back keeps a dragged handle from landing on 7.999999 CPUs.
    private var cpuBinding: Binding<Double> {
        Binding(get: { Double(cpuCount) }, set: { cpuCount = Int($0.rounded()) })
    }

    private var memoryBinding: Binding<Double> {
        Binding(get: { Double(memoryGB) }, set: { memoryGB = Int($0.rounded()) })
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

        // Written first and unconditionally: a re-registration below replaces
        // config.toml but never touches this file, and the next job should be
        // sized by what the sheet said either way.
        if jobVMChanged {
            do {
                try runner.setJobVMSettings(jobVMSettings)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        // Everything short of a re-registration is a line in a file and, at
        // most, a bounce of the process: fast enough to report failure in the
        // sheet that asked for it.
        // (`reregisters` is true whenever there is no registration, so here
        // there is one, and only a changed value needs the runner bounced.)
        if !reregisters {
            if concurrent != original?.concurrent {
                do {
                    try runner.setConcurrent(concurrent)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
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
