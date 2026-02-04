import SwiftUI
import Virtualization

struct ContentView: View {
    @Bindable var vm: VMManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            // Controls
            VStack(alignment: .leading, spacing: 20) {
                Text("Phantom VM Manager")
                    .font(.title2.bold())

                // Image section
                GroupBox("Restore Image") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            imageStatusView
                            Spacer()
                            Button("Download Image") {
                                Task { await vm.downloadImage() }
                            }
                            .disabled(!canDownload)
                        }

                        if case .downloading(let progress) = vm.imageState {
                            ProgressView(value: progress)
                            Text("\(Int(progress * 100))%")
                                .font(.caption.monospacedDigit())
                        }

                        if !vm.imageInfo.isEmpty {
                            Text(vm.imageInfo).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // VM section
                GroupBox("Virtual Machine") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            vmStatusView
                            Spacer()

                            if vm.vmState == .running {
                                Button("Show Display") {
                                    openWindow(id: "vm-display")
                                }
                                Button("Stop") {
                                    Task { await vm.stopVM() }
                                }
                            } else if vm.hasExistingVM {
                                Button("Start VM") {
                                    Task { await vm.startExistingVM() }
                                }
                                .disabled(vm.vmState == .creating)
                            } else {
                                Button("Create & Start VM") {
                                    Task { await vm.createAndStartVM() }
                                }
                                .disabled(!canCreateVM)
                            }
                        }

                        if case .installing(let progress) = vm.vmState {
                            ProgressView(value: progress)
                            Text("Installing: \(Int(progress * 100))%")
                                .font(.caption.monospacedDigit())
                        }

                        if canDeleteVM {
                            Button("Delete VM", role: .destructive) {
                                Task { await vm.deleteVM() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    private var imageStatusView: some View {
        switch vm.imageState {
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

    @ViewBuilder
    private var vmStatusView: some View {
        switch vm.vmState {
        case .none:
            Label("No VM", systemImage: "desktopcomputer")
        case .creating:
            Label("Creating...", systemImage: "gear")
        case .installing:
            Label("Installing macOS...", systemImage: "arrow.triangle.2.circlepath")
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

    // MARK: - Computed

    private var canDownload: Bool {
        vm.imageState == .none || {
            if case .error = vm.imageState { return true }
            return false
        }()
    }

    private var canCreateVM: Bool {
        if case .downloaded = vm.imageState {
            return vm.vmState == .none || vm.vmState == .stopped || {
                if case .error = vm.vmState { return true }
                return false
            }()
        }
        return false
    }

    private var canDeleteVM: Bool {
        vm.vmState == .stopped || vm.vmState == .running || {
            if case .error = vm.vmState { return true }
            return false
        }()
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
