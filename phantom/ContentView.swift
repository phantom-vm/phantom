import SwiftUI
import Virtualization

struct ContentView: View {
    @Bindable var vm: VMManager
    @Environment(\.openWindow) private var openWindow
    @State private var commandText = ""
    @State private var selectedVMId: String?
    @State private var lastExecResult: VMManager.ExecResponse?

    var body: some View {
        HSplitView {
            // Controls
            VStack(alignment: .leading, spacing: 20) {
                Text("Phantom VM Manager")
                    .font(.title2.bold())

                // Image section
                GroupBox("IPSW Images") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ipswStatusView
                            Spacer()
                            Button("Download") {
                                Task { await vm.ipswManager.download() }
                            }
                            .disabled(!canDownload)
                        }

                        if case .downloading(let progress) = vm.ipswManager.state {
                            ProgressView(value: progress)
                            Text("\(Int(progress * 100))%")
                                .font(.caption.monospacedDigit())
                        }

                        if !vm.ipswManager.info.isEmpty {
                            Text(vm.ipswManager.info).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // VM list section
                GroupBox("Virtual Machines") {
                    VStack(alignment: .leading, spacing: 8) {
                        let vms = vm.listVMs()

                        if vms.isEmpty {
                            Text("No VMs")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(vms, id: \.id) { vmInfo in
                                        VMRow(
                                            vmInfo: vmInfo,
                                            isSelected: selectedVMId == vmInfo.id,
                                            vmInstance: vm.vmInstances[vmInfo.id],
                                            onSelect: { selectedVMId = vmInfo.id },
                                            onStart: {
                                                selectedVMId = vmInfo.id
                                                Task { await vm.startVM(vmId: vmInfo.id) }
                                            },
                                            onStop: {
                                                Task { await vm.stopVM(vmId: vmInfo.id) }
                                            },
                                            onDelete: {
                                                Task { await vm.deleteVM(vmId: vmInfo.id) }
                                            },
                                            onShowDisplay: {
                                                vm.setDisplayedVM(vmId: vmInfo.id)
                                                openWindow(id: "vm-display")
                                            }
                                        )
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }

                        Divider()

                        HStack {
                            Button("Create from IPSW") {
                                Task { await vm.createAndStartVM() }
                            }
                            .disabled(!canCreateVM)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Exec section
                if let selectedVMId = selectedVMId,
                   let instance = vm.vmInstances[selectedVMId],
                   case .running = instance.state {
                    GroupBox("Run Command on \(selectedVMId)") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Command", text: $commandText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { runCommand() }
                                Button("Run") { runCommand() }
                                    .disabled(commandText.isEmpty)
                            }

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
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 300, idealWidth: 350)

            // Log area
            GroupBox("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: vm.logs.count) { _, _ in
                        if let last = vm.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding()
            .frame(minWidth: 300)
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    // MARK: - Status Views

    @ViewBuilder
    private var ipswStatusView: some View {
        switch vm.ipswManager.state {
        case .none:
            Label("No image", systemImage: "arrow.down.circle")
        case .fetching:
            Label("Fetching info...", systemImage: "magnifyingglass")
        case .downloading:
            Label("Downloading...", systemImage: "arrow.down.circle.fill")
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Computed

    private func runCommand() {
        guard let vmId = selectedVMId else { return }
        let cmd = commandText
        commandText = ""
        Task { lastExecResult = try? await vm.executeCommand(cmd, vmId: vmId) }
    }

    private var canDownload: Bool {
        vm.ipswManager.state == .none || {
            if case .error = vm.ipswManager.state { return true }
            return false
        }()
    }

    private var canCreateVM: Bool {
        if case .downloaded = vm.ipswManager.state {
            return true
        }
        return false
    }
}

// MARK: - VM Row

struct VMRow: View {
    let vmInfo: VMInfo
    let isSelected: Bool
    let vmInstance: VMManager.VMInstance?
    let onSelect: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    let onShowDisplay: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(vmInfo.id)
                    .font(.system(.body, design: .monospaced))
                if let vmInstance = vmInstance {
                    vmStatusLabel(vmInstance.state)
                        .font(.caption)
                } else {
                    Text(vmInfo.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let vmInstance = vmInstance {
                if vmInstance.state == .running {
                    Button("Display") { onShowDisplay() }
                        .buttonStyle(.bordered)
                    Button("Stop") { onStop() }
                        .buttonStyle(.bordered)
                } else if vmInstance.state == .stopped {
                    Button("Start") { onStart() }
                        .buttonStyle(.bordered)
                } else if case .installing(let progress) = vmInstance.state {
                    ProgressView(value: progress)
                        .frame(width: 60)
                }
            }

            Button("Delete", role: .destructive) { onDelete() }
                .buttonStyle(.bordered)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    @ViewBuilder
    private func vmStatusLabel(_ state: VMManager.VMState) -> some View {
        switch state {
        case .none:
            Label("None", systemImage: "circle")
        case .creating:
            Label("Creating...", systemImage: "gear")
        case .installing:
            Label("Installing...", systemImage: "arrow.triangle.2.circlepath")
        case .running:
            Label("Running", systemImage: "play.circle.fill")
                .foregroundStyle(.green)
        case .stopping:
            Label("Stopping...", systemImage: "stop.circle")
        case .stopped:
            Label("Stopped", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - VM Display

struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = virtualMachine
    }
}

#Preview {
    ContentView(vm: VMManager())
}
