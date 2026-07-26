import SwiftUI

/// Middle column for the VMs section: one row per VM. Every action lives in the
/// detail pane, including the '+' that creates one — this column is a list and
/// nothing else.
struct VMListView: View {
    @Bindable var vm: VMManager
    @Binding var selection: String?
    let onCreateVM: () -> Void

    var body: some View {
        let vms = vm.listVMs()

        Group {
            if vms.isEmpty {
                ContentUnavailableView {
                    Label("No VMs", systemImage: "desktopcomputer")
                } description: {
                    Text("Create one with the + button above the detail pane.")
                } actions: {
                    Button("New VM…") { onCreateVM() }
                }
            } else {
                List(vms, id: \.id, selection: $selection) { info in
                    VMRow(vmInfo: info, instance: vm.vmInstances[info.id])
                }
            }
        }
        .navigationTitle("Virtual Machines")
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
