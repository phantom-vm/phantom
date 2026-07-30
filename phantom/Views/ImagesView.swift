import SwiftUI

/// Middle column for the Images section: the local OCI images a VM can be
/// restored from. Getting another one is the '+' over the detail pane
/// (`PullImageSheet`) or a stopped VM's Save as Image (`SaveImageSheet`);
/// pushing stays a CLI operation.
struct ImageListView: View {
    @Bindable var vm: VMManager
    let images: [ImageInfo]
    @Binding var selection: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let banner {
                operationBanner(banner)
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
                Text("Pull a published one with the + button above the detail pane, or save a stopped VM from its own pane.")
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

    /// What the banner has to say about the shared image manager — including
    /// about an operation the CLI started, since its state is the same state.
    ///
    /// A *completed* one gets no banner: it put an image in the list below, which
    /// says it better than a line of text. A failure has no such trace, and until
    /// the GUI could start a save the only failures were the CLI's own, reported
    /// in the terminal that asked for them.
    private enum Banner {
        case running(progress: Double, message: String)
        case failed(String)
    }

    private var banner: Banner? {
        switch vm.imageManager.state {
        case .saving(let progress, let message),
             .pushing(let progress, let message),
             .pulling(let progress, let message):
            .running(progress: progress, message: message)
        case .error(let message):
            .failed(message)
        case .idle, .completed:
            nil
        }
    }

    @ViewBuilder
    private func operationBanner(_ banner: Banner) -> some View {
        switch banner {
        case .running(let progress, let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                ProgressView(value: progress)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Dismissed by hand rather than on a timer: the failure is the
                // whole account of a save or pull that ran for minutes, and the
                // next operation is the only other thing that clears it.
                Button("Dismiss") { vm.imageManager.clearTerminalState() }
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
