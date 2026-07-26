import SwiftUI

/// The '+' in the VMs column: name the VM, pick what it comes from, and size it.
///
/// Sizing is written into the bundle (`VMSettings`), so the numbers chosen here
/// survive every later start — see `VMManager.buildVMConfiguration`.
struct CreateVMSheet: View {
    @Bindable var vm: VMManager
    let images: [ImageInfo]
    let onCreated: (String) -> Void
    let onBrowseCatalog: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// What the VM is built from. Restoring an image takes minutes; installing
    /// from the restore image takes ~20, which is why it is the fallback rather
    /// than the default.
    enum Source: Hashable {
        case image(String)
        case restoreImage
    }

    @State private var name = VMName.generate()
    @State private var source: Source?
    @State private var cpuCount = VMSettings.defaults.cpuCount
    @State private var memoryGB = Int(VMSettings.defaults.memorySize / (1024 * 1024 * 1024))
    @State private var errorMessage: String?

    private var hasRestoreImage: Bool {
        if case .downloaded = vm.ipswManager.state { return true }
        return false
    }

    private var hasSource: Bool { !images.isEmpty || hasRestoreImage }

    private var maxCPUCount: Int { VMSettings.maximumCPUCount }
    private var minMemoryGB: Int { max(1, Int(VMSettings.minimumMemorySize / (1024 * 1024 * 1024))) }
    private var maxMemoryGB: Int { Int(VMSettings.maximumMemorySize / (1024 * 1024 * 1024)) }

    private var nameError: String? {
        guard VMName.isValid(name) else {
            return "Use letters, digits, '-' and '_' only."
        }
        guard vm.vmInstances[name] == nil else {
            return "A VM with this name already exists."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New VM")
                .font(.headline)
                .padding(20)

            Divider()

            if hasSource {
                form
            } else {
                noImages
            }

            Divider()

            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if hasSource {
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(nameError != nil || source == nil)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .onAppear(perform: selectDefaultSource)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                if let nameError {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("Source", selection: $source) {
                    ForEach(images, id: \.name) { image in
                        Text("\(image.name) — \(image.totalSize.formatted(.byteCount(style: .file)))")
                            .tag(Source.image(image.name) as Source?)
                    }
                    if hasRestoreImage {
                        Text("Restore image (installs macOS, ~20 min)")
                            .tag(Source.restoreImage as Source?)
                    }
                }
            } footer: {
                if images.isEmpty {
                    Text("No local images. The restore image installs a bare macOS; pull a prepared image from the Catalog for anything more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: VMSettings.minimumCPUCount...maxCPUCount)
                Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: minMemoryGB...maxMemoryGB, step: 4)
            } footer: {
                Text("Up to \(maxCPUCount) CPUs and \(maxMemoryGB) GB on this Mac. Stored with the VM and used on every start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Nothing To Create From

    private var noImages: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("No Images", systemImage: "square.stack.3d.up")
            } description: {
                Text("A VM is restored from a local image, or installed from the macOS restore image. This Mac has neither yet.")
            } actions: {
                Button("Browse Catalog") {
                    dismiss()
                    onBrowseCatalog()
                }
                Button("Download Restore Image") {
                    Task { await vm.ipswManager.download() }
                    dismiss()
                }
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: - Actions

    private func selectDefaultSource() {
        guard source == nil else { return }
        // An image restores in minutes and boots ready to use; the IPSW is the
        // fallback for a host that has no image yet.
        if let first = images.first {
            source = .image(first.name)
        } else if hasRestoreImage {
            source = .restoreImage
        }
    }

    private func create() {
        guard nameError == nil, let source else { return }
        let settings = VMSettings(
            cpuCount: cpuCount,
            memorySize: UInt64(memoryGB) * 1024 * 1024 * 1024
        ).clamped()

        switch source {
        case .image(let imageName):
            do {
                let vmId = try vm.createVMFromImage(imageName: imageName, vmId: name, settings: settings)
                onCreated(vmId)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .restoreImage:
            Task { await vm.createAndStartVM(vmId: name, settings: settings) }
            onCreated(name)
            dismiss()
        }
    }
}
