import SwiftUI

/// Middle column for the Images section: the local OCI images a VM can be
/// restored from. Acquiring one is the '+' over the detail pane
/// (`PullImageSheet`); saving and pushing stay CLI operations.
struct ImageListView: View {
    @Bindable var vm: VMManager
    let images: [ImageInfo]
    @Binding var selection: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let operation = operationStatus {
                operationBanner(operation)
                Divider()
            }

            localList
        }
        .navigationTitle("Images")
        .toolbar {
            // Also what keeps the detail column's '+' at its leading edge —
            // that placement holds only while this column has a toolbar item of
            // its own. See `ContentView.detailPane`.
            ToolbarItem {
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan the images directory")
            }
        }
    }

    // MARK: - Local

    @ViewBuilder
    private var localList: some View {
        if images.isEmpty {
            // Description only, no button — the '+' over the detail column is
            // the one way to get an image, and a second control here would
            // teach a spot that stops existing as soon as this pane has a list
            // in it. Same reasoning as `VMListView`.
            ContentUnavailableView {
                Label("No Images", systemImage: "square.stack.3d.up")
            } description: {
                Text("Pull a published one with the + button above the detail pane, or save a stopped VM with `phantom image save`.")
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
    let onCreateVM: (String) -> Void

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
                // The same sheet the '+' opens, with the image already answered
                // — creating one straight from here would hand it defaults the
                // other path lets you choose.
                Button("Create VM") { onCreateVM(info.name) }

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

    private func delete() {
        do {
            try vm.imageManager.delete(name: info.name)
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
