import SwiftUI

/// Right column for a selected VM: its metadata, the lifecycle actions that
/// used to sit on the list row, and the exec console that used to be a GroupBox
/// in the old single-column layout.
struct VMDetailView: View {
    @Bindable var vm: VMManager
    let instance: VMManager.VMInstance
    let onShowDisplay: () -> Void
    let onDeleted: () -> Void

    @State private var commandText = ""
    @State private var lastExecResult: VMManager.ExecResponse?
    @State private var confirmingDelete = false

    private var isRunning: Bool { instance.state == .running }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                metadata

                if isRunning {
                    Divider()
                    execConsole
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(instance.vmId)
        .confirmationDialog(
            "Delete \(instance.vmId)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await vm.deleteVM(vmId: instance.vmId)
                    onDeleted()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The VM bundle and its disk are removed from disk. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(instance.vmId)
                .font(.title2.bold())
                .textSelection(.enabled)

            VMStateLabel(state: instance.state)

            switch instance.state {
            case .installing(let progress), .restoring(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 320)
            default:
                EmptyView()
            }

            HStack(spacing: 8) {
                if isRunning {
                    Button("Stop") {
                        Task { await vm.stopVM(vmId: instance.vmId) }
                    }
                    Button("Display") { onShowDisplay() }
                } else if instance.state == .stopped {
                    Button("Start") {
                        Task { await vm.startVM(vmId: instance.vmId) }
                    }
                }

                Spacer()

                Button("Delete", role: .destructive) {
                    confirmingDelete = true
                }
            }
            .frame(maxWidth: 420)
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            DetailRow(label: "ID", value: instance.vmId, monospaced: true)
            DetailRow(label: "State", value: instance.state.apiString)
            DetailRow(label: "Bundle", value: instance.bundlePath.path, monospaced: true)
        }
    }

    // MARK: - Exec Console

    private var execConsole: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Command")
                .font(.headline)

            HStack {
                TextField("Command", text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runCommand() }
                Button("Run") { runCommand() }
                    .disabled(commandText.isEmpty)
            }
            .frame(maxWidth: 480)

            if let result = lastExecResult {
                VStack(alignment: .leading, spacing: 4) {
                    if !result.stdout.isEmpty {
                        Text(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if !result.stderr.isEmpty {
                        Text(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Text("Exit: \(result.exitCode)")
                        .font(.caption)
                        .foregroundStyle(result.exitCode == 0 ? .green : .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func runCommand() {
        let cmd = commandText
        commandText = ""
        Task { lastExecResult = try? await vm.executeCommand(cmd, vmId: instance.vmId) }
    }
}

// MARK: - Detail Row

/// A label/value pair in a detail pane, with the labels aligned in a column.
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
