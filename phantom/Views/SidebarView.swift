import SwiftUI

/// Left column: the two sections, with a live count each, over a footer for the
/// IPSW restore image. The IPSW belongs here rather than in the Images section —
/// it is a host-level prerequisite for creating a VM from scratch, not one of
/// the OCI images a VM is restored from.
struct SidebarView: View {
    @Bindable var vm: VMManager
    let imageCount: Int
    @Binding var selection: SidebarSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(count(for: section))
            }
            .listStyle(.sidebar)

            Divider()

            ipswFooter
                .padding(12)
        }
        .navigationTitle("Phantom")
    }

    private func count(for section: SidebarSection) -> Int {
        switch section {
        case .vms: vm.vmInstances.count
        case .images: imageCount
        }
    }

    // MARK: - IPSW Footer

    @ViewBuilder
    private var ipswFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Restore Image")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack {
                ipswStatusView
                    .font(.caption)
                Spacer()
                if canDownload {
                    Button("Get") {
                        Task { await vm.ipswManager.download() }
                    }
                    .controlSize(.small)
                }
            }

            if case .downloading(let progress) = vm.ipswManager.state {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !vm.ipswManager.info.isEmpty {
                Text(vm.ipswManager.info)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var ipswStatusView: some View {
        switch vm.ipswManager.state {
        case .none:
            Label("No image", systemImage: "arrow.down.circle")
        case .fetching:
            Label("Fetching info…", systemImage: "magnifyingglass")
        case .downloading:
            Label("Downloading…", systemImage: "arrow.down.circle.fill")
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var canDownload: Bool {
        switch vm.ipswManager.state {
        case .none, .error: true
        default: false
        }
    }
}
