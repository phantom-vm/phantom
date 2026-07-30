import SwiftUI

/// What the sidebar lists, in two groups: the things the daemon manages, then the
/// daemon itself. Most entries get a list in the middle column and a detail pane
/// on the right; `.log` is one page and says so via `hasListColumn`.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case vms
    case images
    case log
    case integration

    var id: Self { self }

    /// The entries above the "Daemon" header, and the ones under it.
    static let resourceSections: [SidebarSection] = [.vms, .images]
    static let daemonSections: [SidebarSection] = [.log, .integration]

    var title: String {
        switch self {
        case .vms: "VMs"
        case .images: "Images"
        case .log: "Log"
        case .integration: "Integration"
        }
    }

    var systemImage: String {
        switch self {
        case .vms: "desktopcomputer"
        case .images: "square.stack.3d.up"
        case .log: "text.alignleft"
        case .integration: "puzzlepiece.extension"
        }
    }

    /// Whether the middle column has anything to list. The log is a single page,
    /// so its column collapses and the log fills the width beside the sidebar.
    var hasListColumn: Bool {
        switch self {
        case .vms, .images, .integration: true
        case .log: false
        }
    }
}

struct ContentView: View {
    @Bindable var vm: VMManager
    @Environment(\.openWindow) private var openWindow

    @State private var section: SidebarSection? = .vms
    @State private var selectedVMId: String?
    @State private var selectedImageName: String?
    @State private var selectedIntegration: Integration? = .gitlabRunner
    @State private var pullingImage = false

    /// The New VM sheet, and the image it opens with. Non-nil is what presents
    /// it — the '+' passes an empty string, an image's own Create VM passes its
    /// name. Presented by item rather than a flag so the sheet is rebuilt per
    /// request and its prefill takes.
    @State private var newVMRequest: NewVMRequest?

    /// The Save as Image sheet, and the VM it was opened from. Presented by item
    /// for the same reason the New VM sheet is, and carrying the bundle path so
    /// the sheet never has to look the instance up to start the save.
    @State private var saveImageRequest: SaveImageRequest?

    /// Carries the prefill into `.sheet(item:)`, which needs something
    /// Identifiable — a bare String is not, and conforming the stdlib's is a
    /// heavier thing to do than naming the request.
    private struct NewVMRequest: Identifiable {
        let id = UUID()
        let image: String
    }

    private struct SaveImageRequest: Identifiable {
        let id = UUID()
        let vmId: String
        let bundlePath: URL
    }

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
        // Two shapes of window, chosen by the selected section. A three-column
        // NavigationSplitView cannot hide its middle column — neither
        // `navigationSplitViewColumnWidth(0)` nor `columnVisibility` reaches it —
        // so a section with nothing to list gets a genuinely two-column split view
        // instead, and its page fills everything right of the sidebar.
        Group {
            if currentSection.hasListColumn {
                NavigationSplitView {
                    sidebar
                } content: {
                    listColumn
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
                } detail: {
                    detailPane
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detailPane
                }
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

    private var sidebar: some View {
        SidebarView(vm: vm, imageCount: images.count, selection: $section)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
    }

    private var detailPane: some View {
        detail
            // Declaring this on the detail column is what puts it at that
            // column's leading edge, just right of the split divider — no
            // placement names that spot, the column is the whole lever.
            // It only holds there while the content column has a toolbar
            // item of its own, otherwise it drifts to the window's
            // trailing edge: in the VMs section `VMListView`'s filter menu
            // is what keeps it put.
            .toolbar {
                if currentSection == .vms {
                    ToolbarItem {
                        Button {
                            newVMRequest = NewVMRequest(image: "")
                        } label: {
                            Label("New VM", systemImage: "plus")
                        }
                        .help("Create a VM from a local image")
                    }
                }
                if currentSection == .images {
                    ToolbarItem {
                        Button {
                            pullingImage = true
                        } label: {
                            Label("Pull Image", systemImage: "plus")
                        }
                        .help("Pull a published image")
                    }
                }
            }
            .sheet(item: $newVMRequest) { request in
                CreateVMSheet(vm: vm, image: request.image) { vmId in
                    selectedVMId = vmId
                    section = .vms
                }
            }
            .sheet(isPresented: $pullingImage) {
                PullImageSheet(vm: vm, onPullStarted: reloadImages)
            }
            .sheet(item: $saveImageRequest) { request in
                SaveImageSheet(vm: vm, vmId: request.vmId, bundlePath: request.bundlePath) { name in
                    // Go where the result lands: the save runs for minutes, and
                    // the Images list is what draws its progress and then holds
                    // the image. Selecting the name now means the detail pane is
                    // already on it when the list reloads — until then it reads
                    // as no selection, which is true.
                    selectedImageName = name
                    section = .images
                }
            }
    }

    private func reloadImages() {
        images = vm.imageManager.list()
    }

    // MARK: - List Column

    @ViewBuilder
    private var listColumn: some View {
        switch currentSection {
        case .vms:
            VMListView(vm: vm, selection: $selectedVMId)
        case .images:
            ImageListView(
                vm: vm,
                images: images,
                selection: $selectedImageName,
                onRefresh: reloadImages
            )
        case .integration:
            IntegrationListView(vm: vm, selection: $selectedIntegration)
        case .log:
            // Never built: `.log` takes the two-column window, which has no
            // middle column to put this in.
            EmptyView()
        }
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
                    onSaveAsImage: {
                        saveImageRequest = SaveImageRequest(
                            vmId: instance.vmId,
                            bundlePath: instance.bundlePath
                        )
                    },
                    onDeleted: { selectedVMId = nil }
                )
                .id(instance.vmId)
            } else {
                noSelection("No Selection", description: "Select a virtual machine to see its details.")
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
                    onCreateVM: { newVMRequest = NewVMRequest(image: $0) }
                )
                .id(info.name)
            } else {
                noSelection("No Selection", description: "Select an image to see its details.")
            }
        case .log:
            DaemonLogView(lines: vm.logs.lines)
        case .integration:
            switch selectedIntegration {
            case .gitlabRunner:
                GitLabRunnerDetailView(vm: vm)
            case .githubRunner:
                GitHubRunnerDetailView()
            case nil:
                noSelection("No Selection", description: "Select an integration to see its status.")
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
