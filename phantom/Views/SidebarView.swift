import SwiftUI

/// Left column, in two groups: the things the daemon manages (with a live count
/// each), then the daemon itself — its log and its integrations.
///
/// Nothing about the macOS restore image (IPSW) appears here, or anywhere else in
/// the GUI. A user's starting point is a published catalog image, pulled ready to
/// boot; an IPSW is how those images get built, which is an authoring concern —
/// the CLI already gates `ipsw` behind `PHANTOM_ADMIN_MODE` for the same reason.
/// The daemon still serves the endpoints, so `phantom image build --ipsw` works.
struct SidebarView: View {
    @Bindable var vm: VMManager
    let imageCount: Int
    @Binding var selection: SidebarSection?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarSection.resourceSections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(count(for: section))
                        .tag(section)
                }
            }

            Section("Daemon") {
                ForEach(SidebarSection.daemonSections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Phantom")
    }

    private func count(for section: SidebarSection) -> Int {
        switch section {
        case .vms: vm.vmInstances.count
        case .images: imageCount
        case .log, .integration: 0
        }
    }
}
