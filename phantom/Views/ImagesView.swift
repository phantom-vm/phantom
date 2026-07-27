import SwiftUI

/// Which images the middle column is showing: what is on disk, or what the
/// published catalog offers.
enum ImageScope: String, CaseIterable, Identifiable, Hashable {
    case local
    case catalog

    var id: Self { self }
    var title: String { self == .local ? "Local" : "Catalog" }
}

/// Middle column for the Images section: the local OCI images a VM can be
/// restored from, and — under Catalog — the published ones it can pull. Saving
/// and pushing stay CLI operations.
struct ImageListView: View {
    @Bindable var vm: VMManager
    let images: [ImageInfo]
    @Binding var scope: ImageScope
    @Binding var selection: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scope) {
                ForEach(ImageScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            if let operation = operationStatus {
                operationBanner(operation)
                Divider()
            }

            switch scope {
            case .local: localList
            case .catalog: catalogList
            }
        }
        .navigationTitle("Images")
        .toolbar {
            ToolbarItem {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help(scope == .local ? "Rescan the images directory" : "Fetch the catalog again")
            }
        }
        .task(id: scope) {
            // Fetched on first visit rather than at launch: a daemon that never
            // opens this tab should not be reaching out to a registry.
            if scope == .catalog, case .idle = vm.catalogManager.state {
                await vm.catalogManager.load()
            }
        }
    }

    private func refresh() {
        switch scope {
        case .local: onRefresh()
        case .catalog: Task { await vm.catalogManager.load() }
        }
    }

    // MARK: - Local

    @ViewBuilder
    private var localList: some View {
        if images.isEmpty {
            ContentUnavailableView {
                Label("No Images", systemImage: "square.stack.3d.up")
            } description: {
                Text("Pull a published one from the Catalog tab, or save a stopped VM with `phantom image save`.")
            }
        } else {
            List(images, id: \.name, selection: $selection) { info in
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name)
                        .font(.system(.body, design: .monospaced))
                    Text("\(info.totalSize.formatted(.byteCount(style: .file))) · \(info.diskChunks) chunks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Catalog

    @ViewBuilder
    private var catalogList: some View {
        switch vm.catalogManager.state {
        case .idle, .loading:
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView {
                Label("Catalog Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await vm.catalogManager.load() }
                }
            }
        case .loaded(let entries):
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Catalog Empty", systemImage: "square.stack.3d.up")
                } description: {
                    Text("\(CatalogManager.url) lists no images.")
                }
            } else {
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.system(.body, design: .monospaced))
                        HStack(spacing: 4) {
                            Text(entry.compressedSize.formatted(.byteCount(style: .file)))
                            if vm.imageManager.imageExists(entry.name) {
                                Text("· Local")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// The in-flight image operation, if any — including ones started over the
    /// API by the CLI, since the manager's state is shared.
    private var operationStatus: (progress: Double, message: String)? {
        switch vm.imageManager.state {
        case .saving(let progress, let message),
             .pushing(let progress, let message),
             .pulling(let progress, let message):
            (progress, message)
        case .idle, .completed, .error:
            nil
        }
    }

    private func operationBanner(_ operation: (progress: Double, message: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(operation.message)
                .font(.caption)
                .lineLimit(2)
            ProgressView(value: operation.progress)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Image Detail

struct ImageDetailView: View {
    @Bindable var vm: VMManager
    let info: ImageInfo
    let onDeleted: () -> Void
    let onVMCreated: (String) -> Void

    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                metadata

                if let pull = info.pulledFrom {
                    Divider()
                    origin(pull)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(info.name)
        .confirmationDialog(
            "Delete \(info.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The image is removed from disk. VMs already restored from it are unaffected.")
        }
        .alert("Image Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.name)
                .font(.title2.bold())
                .textSelection(.enabled)

            Text(info.totalSize.formatted(.byteCount(style: .file)))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                // Restoring decompresses the whole disk, so this returns a vmId
                // immediately and the VM shows its progress in the VMs section.
                Button("Create VM") { createVM() }

                Spacer()

                Button("Delete", role: .destructive) {
                    confirmingDelete = true
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            DetailRow(label: "Name", value: info.name, monospaced: true)
            DetailRow(label: "Size", value: info.totalSize.formatted(.byteCount(style: .file)))
            DetailRow(label: "Chunks", value: "\(info.diskChunks)")
            DetailRow(label: "Created", value: info.createdAt)
        }
    }

    private func origin(_ pull: PullRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulled From")
                .font(.headline)

            DetailRow(label: "Reference", value: pull.reference, monospaced: true)
            DetailRow(label: "Digest", value: pull.digest, monospaced: true)
            DetailRow(label: "Pulled", value: pull.pulledAt)
        }
    }

    private func createVM() {
        do {
            onVMCreated(try vm.createVMFromImage(imageName: info.name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try vm.imageManager.delete(name: info.name)
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Catalog Detail

/// Right column for a catalog entry: what the image is, and the one action that
/// applies to it. Pulling is a long download, so the button hands off to
/// `OCIImageManager` and the progress shows over the list like any other image
/// operation — including one the CLI started.
struct CatalogDetailView: View {
    @Bindable var vm: VMManager
    let entry: CatalogEntry
    let onPullStarted: () -> Void

    private var isLocal: Bool { vm.imageManager.imageExists(entry.name) }

    private var isBusy: Bool {
        switch vm.imageManager.state {
        case .saving, .pushing, .pulling: true
        case .idle, .completed, .error: false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(entry.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.name)
                .font(.title2.bold())
                .textSelection(.enabled)

            Text(entry.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if isLocal {
                Label("Already pulled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                HStack(spacing: 8) {
                    Button("Pull") { pull() }
                        .disabled(isBusy)
                    Text("\(entry.compressedSize.formatted(.byteCount(style: .file))) to download, \(entry.diskSize.formatted(.byteCount(style: .file))) restored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            DetailRow(label: "Name", value: entry.name, monospaced: true)
            DetailRow(label: "Download", value: entry.compressedSize.formatted(.byteCount(style: .file)))
            DetailRow(label: "Restored", value: entry.diskSize.formatted(.byteCount(style: .file)))
            DetailRow(label: "Published", value: entry.published)
            DetailRow(label: "Repository", value: entry.repository, monospaced: true)
            DetailRow(label: "Digest", value: entry.digest, monospaced: true)
        }
    }

    private func pull() {
        // By digest, not by tag: the catalog only points, and pinning here is
        // what keeps a retagged registry from substituting another image.
        Task {
            await vm.imageManager.pull(
                reference: entry.pullReference,
                name: entry.name,
                username: nil,
                password: nil
            )
            onPullStarted()
        }
    }
}
