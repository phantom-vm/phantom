import SwiftUI

/// What the sidebar lists. The daemon manages two kinds of thing, and each gets
/// a list in the middle column and a detail pane on the right.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case vms
    case images

    var id: Self { self }

    var title: String {
        switch self {
        case .vms: "VMs"
        case .images: "Images"
        }
    }

    var systemImage: String {
        switch self {
        case .vms: "desktopcomputer"
        case .images: "square.stack.3d.up"
        }
    }
}

struct ContentView: View {
    @Bindable var vm: VMManager
    @Environment(\.openWindow) private var openWindow

    @State private var section: SidebarSection? = .vms
    @State private var selectedVMId: String?
    @State private var selectedImageName: String?
    @State private var imageScope: ImageScope = .local
    @State private var showLog = false

    /// Listing images walks the images directory, so it is cached here — both
    /// the list and the detail pane read this copy — and reloaded when an image
    /// operation reaches a terminal state (see `imagesReloadKey`).
    @State private var images: [ImageInfo] = []

    private var currentSection: SidebarSection { section ?? .vms }

    /// Flips whenever an image operation starts or finishes, without tracking
    /// the progress inside one — a pull ticking from 1% to 100% must not rescan
    /// the directory on every update.
    private var imagesReloadKey: Bool {
        switch vm.imageManager.state {
        case .idle, .completed, .error: true
        case .saving, .pushing, .pulling: false
        }
    }

    var body: some View {
        // The log used to own half the window; it is a debugging aid, so it
        // sits below the three columns and starts collapsed.
        VSplitView {
            NavigationSplitView {
                SidebarView(vm: vm, imageCount: images.count, selection: $section)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
            } content: {
                Group {
                    switch currentSection {
                    case .vms:
                        VMListView(vm: vm, selection: $selectedVMId)
                    case .images:
                        ImageListView(
                            vm: vm,
                            images: images,
                            scope: $imageScope,
                            selection: $selectedImageName,
                            onRefresh: reloadImages
                        )
                        // Local and catalog names live in one selection, so
                        // switching tabs must not leave a stale one behind.
                        .onChange(of: imageScope) { selectedImageName = nil }
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
            } detail: {
                detail
                    .toolbar {
                        ToolbarItem {
                            Button {
                                showLog.toggle()
                            } label: {
                                Label("Log", systemImage: "text.alignleft")
                            }
                            .help(showLog ? "Hide the daemon log" : "Show the daemon log")
                        }
                    }
            }

            if showLog {
                LogPane(logs: vm.logs)
                    .frame(minHeight: 100, idealHeight: 160)
            }
        }
        .frame(minWidth: 820, minHeight: 460)
        .task(id: imagesReloadKey) {
            reloadImages()
        }
        .onChange(of: vm.displayRequestCounter) {
            openWindow(id: "vm-display")
        }
    }

    private func reloadImages() {
        images = vm.imageManager.list()
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detail: some View {
        switch currentSection {
        case .vms:
            // Looking the instance up here rather than holding it means a VM
            // that disappears (deleted from the GUI or over the API) falls back
            // to the placeholder instead of showing a stale pane.
            if let vmId = selectedVMId, let instance = vm.vmInstances[vmId] {
                VMDetailView(
                    vm: vm,
                    instance: instance,
                    onShowDisplay: {
                        vm.setDisplayedVM(vmId: instance.vmId)
                        openWindow(id: "vm-display")
                    },
                    onDeleted: { selectedVMId = nil }
                )
                .id(instance.vmId)
            } else {
                noSelection("No Selection", description: "Select a virtual machine to see its details.")
            }
        case .images where imageScope == .catalog:
            if let name = selectedImageName,
               let entry = vm.catalogManager.entries.first(where: { $0.name == name }) {
                CatalogDetailView(vm: vm, entry: entry, onPullStarted: reloadImages)
                    .id(entry.name)
            } else {
                noSelection("No Selection", description: "Select a published image to see what it contains.")
            }
        case .images:
            if let name = selectedImageName, let info = images.first(where: { $0.name == name }) {
                ImageDetailView(
                    vm: vm,
                    info: info,
                    onDeleted: {
                        selectedImageName = nil
                        reloadImages()
                    },
                    onVMCreated: { vmId in
                        selectedVMId = vmId
                        section = .vms
                    }
                )
                .id(info.name)
            } else {
                noSelection("No Selection", description: "Select an image to see its details.")
            }
        }
    }

    private func noSelection(_ title: String, description: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: currentSection.systemImage,
            description: Text(description)
        )
    }
}

#Preview {
    ContentView(vm: VMManager())
}
