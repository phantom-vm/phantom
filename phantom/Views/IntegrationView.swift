import SwiftUI

/// The CI integrations the daemon can host. GitLab is the one that works; GitHub
/// is listed so the shape of the section is honest about what is coming, rather
/// than the section looking like it is only ever about GitLab.
enum Integration: String, CaseIterable, Identifiable, Hashable {
    case gitlabRunner
    case githubRunner

    var id: Self { self }

    var title: String {
        switch self {
        case .gitlabRunner: "GitLab Runner"
        case .githubRunner: "GitHub Runner"
        }
    }

    var systemImage: String {
        switch self {
        case .gitlabRunner: "gearshape.2"
        case .githubRunner: "gearshape.2"
        }
    }
}

// MARK: - List Column

struct IntegrationListView: View {
    @Bindable var vm: VMManager
    @Binding var selection: Integration?

    var body: some View {
        List(Integration.allCases, selection: $selection) { integration in
            VStack(alignment: .leading, spacing: 3) {
                Text(integration.title)
                switch integration {
                case .gitlabRunner:
                    GitLabRunnerStateLabel(state: vm.gitlabRunnerManager.state)
                        .font(.caption)
                case .githubRunner:
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .tag(integration)
        }
        .navigationTitle("Integration")
    }
}

// MARK: - State Label

/// One rendering of the runner's state, shared by the list row and the Info tab.
struct GitLabRunnerStateLabel: View {
    let state: GitLabRunnerManager.State

    var body: some View {
        switch state {
        case .notConfigured:
            Label("Not configured", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .downloading:
            Label("Downloading…", systemImage: "arrow.down.circle")
        case .registering:
            Label("Registering…", systemImage: "gear")
        case .running:
            Label("Running", systemImage: "play.circle.fill")
                .foregroundStyle(.green)
        case .stopped:
            Label("Stopped", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        case .error(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

// MARK: - GitLab Runner Detail

struct GitLabRunnerDetailView: View {
    @Bindable var vm: VMManager

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case info
        case log

        var id: Self { self }
        var title: String {
            switch self {
            case .info: "Info"
            case .log: "Log"
            }
        }
    }

    @State private var tab: Tab = .info
    @State private var errorMessage: String?
    @State private var configuring = false

    private var runner: GitLabRunnerManager { vm.gitlabRunnerManager }

    /// Read once per body pass rather than stored: `setup` writes the file and
    /// publishes its state, and this view redraws on that.
    private var configuration: GitLabRunnerManager.Configuration? { runner.currentConfiguration() }

    var body: some View {
        Group {
            switch tab {
            case .info: info
            case .log:
                LogLinesView(
                    lines: runner.output.lines,
                    emptyMessage: "The runner logs here once it starts. Register it with 'phantom gitlab-runner setup'."
                )
            }
        }
        .navigationTitle("GitLab Runner")
        .sheet(isPresented: $configuring) {
            GitLabRunnerConfigSheet(vm: vm)
        }
        // In the toolbar rather than the pane body: which view of the runner you
        // are looking at is navigation, not content, and a header band inside the
        // pane costs vertical space on every tab. Declared here, on the detail
        // column, so it lands at that column's leading edge.
        .toolbar {
            ToolbarItem {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: Info

    private var info: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitLab Runner")
                        .font(.title2.bold())

                    GitLabRunnerStateLabel(state: runner.state)

                    HStack(spacing: 8) {
                        if runner.isRunning {
                            Button("Stop") { runner.stop() }
                        } else {
                            Button("Start") {
                                Task {
                                    do { try await runner.start() } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(!runner.isConfigured)
                        }
                        Button(runner.isConfigured ? "Configure…" : "Register…") { configuring = true }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Details")
                        .font(.headline)

                    DetailRow(label: "State", value: stateDescription)
                    DetailRow(label: "Registered", value: runner.isConfigured ? "Yes" : "No")
                    DetailRow(label: "Running", value: runner.isRunning ? "Yes" : "No")
                    if let configuration {
                        DetailRow(label: "GitLab", value: configuration.url)
                        DetailRow(label: "Concurrent", value: "\(configuration.concurrent)")
                    }
                    DetailRow(label: "Version", value: GitLabRunnerManager.runnerVersion)
                    DetailRow(label: "Binary", value: runner.isBinaryDownloaded ? "Downloaded" : "Not downloaded")
                    DetailRow(label: "Config", value: runner.configPath.path, monospaced: true)
                }

                if !runner.isConfigured {
                    Divider()
                    setupHint
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not registered yet")
                .font(.headline)
            Text("Registering needs a GitLab URL and a runner token — Register… above, or 'phantom gitlab-runner setup --token glrt-xxx' from a terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Every job then gets a fresh VM, created from the image its 'image:' names and deleted afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateDescription: String {
        switch runner.state {
        case .notConfigured: "Not configured"
        case .downloading: "Downloading"
        case .registering: "Registering"
        case .running: "Running"
        case .stopped: "Stopped"
        case .error(let message): "Error: \(message)"
        }
    }
}

// MARK: - GitHub Runner Detail

struct GitHubRunnerDetailView: View {
    var body: some View {
        ContentUnavailableView {
            Label("GitHub Runner", systemImage: "gearshape.2")
        } description: {
            Text("Coming soon. Phantom hosts a GitLab runner today; a GitHub Actions runner is not implemented yet.")
        }
        .navigationTitle("GitHub Runner")
    }
}
