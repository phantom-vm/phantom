import SwiftUI

/// The '+' over the VM detail pane: name the VM, name the image it comes from,
/// and size it.
///
/// Sizing is written into the bundle (`VMSettings`), so the numbers chosen here
/// survive every later start — see `VMManager.buildVMConfiguration`.
///
/// A local image is the only source offered. The daemon can also install a VM
/// from a macOS restore image (`vm.create --ipswId`), but that is a ~20-minute
/// bare-macOS install used to *build* images, not to get a working VM — so it
/// stays with the authoring tools in the CLI and out of the GUI.
///
/// The image is typed rather than picked. A picker could only ever offer what is
/// already on this Mac, and browsing images is the Images section's job; a name
/// that isn't there fails on Create with the daemon's own message.
struct CreateVMSheet: View {
    @Bindable var vm: VMManager
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = VMName.generate()
    @State private var source: String

    /// - Parameter image: prefills the image field. An image's own "Create VM"
    ///   opens this sheet with the name already answered; the '+' opens it empty.
    init(vm: VMManager, image: String = "", onCreated: @escaping (String) -> Void) {
        self.vm = vm
        self.onCreated = onCreated
        _source = State(initialValue: image)
    }
    @State private var cpuCount = VMSettings.defaults.cpuCount
    @State private var memoryGB = Int(VMSettings.defaults.memorySize / (1024 * 1024 * 1024))
    @State private var errorMessage: String?

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

    private var trimmedSource: String {
        source.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New VM")
                .font(.headline)
                .padding(20)

            Divider()

            form

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
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameError != nil || trimmedSource.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 460)
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
                TextField("Image", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Section {
                // The value is what matters, so it is labelled and kept beside
                // the slider — a bare track leaves the reader guessing where
                // the handle actually landed.
                LabeledContent("CPUs") {
                    HStack {
                        Slider(
                            value: cpuBinding,
                            in: Double(VMSettings.minimumCPUCount)...Double(maxCPUCount),
                            step: 1
                        ) {
                            EmptyView()
                        } minimumValueLabel: {
                            bound("\(VMSettings.minimumCPUCount)")
                        } maximumValueLabel: {
                            bound("\(maxCPUCount)")
                        }
                        Text("\(cpuCount)")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                LabeledContent("Memory") {
                    HStack {
                        // No `step:`. A stepped slider snaps to a grid anchored
                        // at the lower bound, which put the ceiling shown at the
                        // right of the track out of reach (1, 5, 9 … 29 against
                        // a stated maximum of 32); at 1GB the grid reaches it
                        // but draws a tick per GB. The binding already rounds,
                        // so dragging is continuous and the value is whole.
                        Slider(
                            value: memoryBinding,
                            in: Double(minMemoryGB)...Double(maxMemoryGB)
                        ) {
                            EmptyView()
                        } minimumValueLabel: {
                            bound("\(minMemoryGB)")
                        } maximumValueLabel: {
                            bound("\(maxMemoryGB)")
                        }
                        Text("\(memoryGB) GB")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The ends of a track, so the handle reads as a proportion of what this Mac
    /// allows rather than a bare position. Both ceilings come from
    /// Virtualization.framework and differ by machine, which is exactly why they
    /// are worth showing.
    private func bound(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    /// Slider works in Double; the settings are integers. Rounding on the way
    /// back keeps a dragged handle from landing on 7.999999 CPUs.
    private var cpuBinding: Binding<Double> {
        Binding(get: { Double(cpuCount) }, set: { cpuCount = Int($0.rounded()) })
    }

    private var memoryBinding: Binding<Double> {
        Binding(get: { Double(memoryGB) }, set: { memoryGB = Int($0.rounded()) })
    }

    // MARK: - Actions

    private func create() {
        guard nameError == nil, !trimmedSource.isEmpty else { return }
        let settings = VMSettings(
            cpuCount: cpuCount,
            memorySize: UInt64(memoryGB) * 1024 * 1024 * 1024
        ).clamped()

        do {
            let vmId = try vm.createVMFromImage(imageName: trimmedSource, vmId: name, settings: settings)
            onCreated(vmId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
