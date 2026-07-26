import SwiftUI

/// Middle column for the VMs section: one row per VM, plus the filter that says
/// which rows. Actions on a VM live in the detail pane, as does the '+' that
/// creates one.
struct VMListView: View {
    @Bindable var vm: VMManager
    @Binding var selection: String?

    /// Remembered across launches: a user who hides stopped VMs means it.
    @AppStorage("showStoppedVMs") private var showStoppedVMs = true

    /// Only `.stopped` is hidden. The transitional states and `.error` always
    /// show — a VM that is installing, restoring or broken is the one you most
    /// need to see, and hiding it is how it gets forgotten about.
    private var visibleVMs: [VMInfo] {
        let all = vm.listVMs()
        guard !showStoppedVMs else { return all }
        return all.filter { vm.vmInstances[$0.id]?.state != .stopped }
    }

    var body: some View {
        let vms = visibleVMs

        Group {
            if vms.isEmpty {
                // Description only, no button. The '+' over the detail column is
                // the one way to create a VM, and a second control here would
                // both duplicate it and teach a spot that stops existing as soon
                // as this pane has a list in it.
                ContentUnavailableView {
                    Label(showStoppedVMs ? "No VMs" : "No Running VMs", systemImage: "desktopcomputer")
                } description: {
                    Text(showStoppedVMs
                         ? "Create one with the + button above the detail pane."
                         : "Stopped VMs are hidden by the filter above.")
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
                Menu {
                    Toggle("Show Stopped VMs", isOn: $showStoppedVMs)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Choose which VMs the list shows")
            }
        }
        // A row can leave the list without the selection changing — the filter is
        // switched off, or the selected VM stops — and the detail pane would then
        // outlive its row.
        .onChange(of: vms.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
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
