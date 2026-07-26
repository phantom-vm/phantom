import SwiftUI

/// The '+' over the VM detail pane: name the VM, pick the image it comes from,
/// and size it.
///
/// Sizing is written into the bundle (`VMSettings`), so the numbers chosen here
/// survive every later start — see `VMManager.buildVMConfiguration`.
///
/// A local image is the only source offered. The daemon can also install a VM
/// from a macOS restore image (`vm.create --ipswId`), but that is a ~20-minute
/// bare-macOS install used to *build* images, not to get a working VM — so it
/// stays with the authoring tools in the CLI and out of the GUI.
struct CreateVMSheet: View {
    @Bindable var vm: VMManager
    let images: [ImageInfo]
    let onCreated: (String) -> Void
    let onBrowseCatalog: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = VMName.generate()
    @State private var source: String?
    @State private var cpuCount = VMSettings.defaults.cpuCount
    @State private var memoryGB = Int(VMSettings.defaults.memorySize / (1024 * 1024 * 1024))
    @State private var errorMessage: String?

    private var hasSource: Bool { !images.isEmpty }

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
                Picker("Image", selection: $source) {
                    ForEach(images, id: \.name) { image in
                        Text("\(image.name) — \(image.totalSize.formatted(.byteCount(style: .file)))")
                            .tag(image.name as String?)
                    }
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
                Text("A VM is restored from a local image, and this Mac has none yet. The Catalog lists prepared images ready to boot.")
            } actions: {
                Button("Browse Catalog") {
                    dismiss()
                    onBrowseCatalog()
                }
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: - Actions

    private func selectDefaultSource() {
        guard source == nil else { return }
        source = images.first?.name
    }

    private func create() {
        guard nameError == nil, let source else { return }
        let settings = VMSettings(
            cpuCount: cpuCount,
            memorySize: UInt64(memoryGB) * 1024 * 1024 * 1024
        ).clamped()

        do {
            let vmId = try vm.createVMFromImage(imageName: source, vmId: name, settings: settings)
            onCreated(vmId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
