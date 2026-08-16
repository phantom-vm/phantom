import SwiftUI

/// The '+' over the image detail pane: what the published catalog offers, and
/// the one action that applies to it.
///
/// A sheet rather than a second tab in the middle column. The catalog is a
/// remote index consulted in order to *acquire* an image — an action — where the
/// list behind it is what this Mac already has. Mixing the two in one column is
/// what used to force a Local/Catalog switch on the section.
///
/// Pulling hands off to `OCIImageManager` and dismisses: the download is long,
/// and its progress belongs over the list with every other image operation,
/// including one the CLI started.
struct PullImageSheet: View {
    @Bindable var vm: VMManager
    let onPullStarted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?

    private var isBusy: Bool {
        switch vm.imageManager.state {
        case .saving, .pushing, .pulling: true
        case .idle, .completed, .cancelled, .error: false
        }
    }

    private var selectedEntry: CatalogEntry? {
        guard let selection else { return nil }
        return vm.catalogManager.entries.first { $0.name == selection }
    }

    /// A pull that would land on a name already here is refused rather than
    /// silently replacing it — updating an image is `phantom image pull --force`,
    /// which knows how to compare digests first.
    private var canPull: Bool {
        guard let entry = selectedEntry else { return false }
        return !isBusy && !vm.imageManager.imageExists(entry.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pull Image")
                .font(.headline)
                .padding(20)

            Divider()

            content
                .frame(height: 260)

            Divider()

            HStack {
                if let entry = selectedEntry {
                    Text("\(entry.compressedSize.formatted(.byteCount(style: .file))) to download, \(entry.diskSize.formatted(.byteCount(style: .file))) restored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pull") { pull() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPull)
            }
            .padding(20)
        }
        .frame(width: 560)
        .task {
            // Fetched on first open rather than at launch: a daemon nobody asks
            // for an image should not be reaching out to a registry.
            if case .idle = vm.catalogManager.state {
                await vm.catalogManager.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
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
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.system(.body, design: .monospaced))
                if vm.imageManager.imageExists(entry.name) {
                    Label("Already pulled", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("Already on this Mac")
                }
                Spacer()
                Text(entry.compressedSize.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func pull() {
        guard let entry = selectedEntry else { return }
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
        dismiss()
    }
}
