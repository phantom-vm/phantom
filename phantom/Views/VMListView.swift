import SwiftUI

/// Middle column for the VMs section: one row per VM, actions live in the
/// detail pane. The only action here is creating a VM, which belongs to the
/// list rather than to any one row.
struct VMListView: View {
    @Bindable var vm: VMManager
    @Binding var selection: String?

    var body: some View {
        let vms = vm.listVMs()

        Group {
            if vms.isEmpty {
                ContentUnavailableView {
                    Label("No VMs", systemImage: "desktopcomputer")
                } description: {
                    Text(canCreateVM
                        ? "Create one from the restore image, or from an image in the Images section."
                        : "Download the restore image first, or restore one from the Images section.")
                }
            } else {
                List(vms, id: \.id, selection: $selection) { info in
                    VMRow(vmInfo: info, instance: vm.vmInstances[info.id])
                }
            }
        }
        .navigationTitle("Virtual Machines")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await vm.createAndStartVM() }
                } label: {
                    Label("Create VM from restore image", systemImage: "plus")
                }
                .disabled(!canCreateVM)
                .help("Install a new VM from the downloaded restore image")
            }
        }
    }

    private var canCreateVM: Bool {
        if case .downloaded = vm.ipswManager.state { return true }
        return false
    }
}

// MARK: - VM Row

struct VMRow: View {
    let vmInfo: VMInfo
    let instance: VMManager.VMInstance?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(vmInfo.id)
                .font(.system(.body, design: .monospaced))

            if let instance {
                VMStateLabel(state: instance.state)
                    .font(.caption)

                switch instance.state {
                case .installing(let progress), .restoring(let progress):
                    ProgressView(value: progress)
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            } else {
                Text(vmInfo.state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - VM State Label

/// One rendering of `VMState`, shared by the list row and the detail pane.
struct VMStateLabel: View {
    let state: VMManager.VMState

    var body: some View {
        switch state {
        case .none:
            Label("None", systemImage: "circle")
        case .creating:
            Label("Creating…", systemImage: "gear")
        case .installing(let progress):
            Label("Installing… \(Int(progress * 100))%", systemImage: "arrow.triangle.2.circlepath")
        case .restoring(let progress):
            Label("Restoring… \(Int(progress * 100))%", systemImage: "arrow.down.doc")
        case .running:
            Label("Running", systemImage: "play.circle.fill")
                .foregroundStyle(.green)
        case .stopping:
            Label("Stopping…", systemImage: "stop.circle")
        case .stopped:
            Label("Stopped", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
