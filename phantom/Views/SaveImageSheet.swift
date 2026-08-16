import SwiftUI

/// "Save as Image" on a stopped VM: its bundle becomes a local OCI image under
/// the name given here.
///
/// A sheet for the same reason `PullImageSheet` is one — the Images list is what
/// this Mac has, and producing another one is an action. It hands off to
/// `OCIImageManager.save` and dismisses: chunking a disk takes minutes, and the
/// progress belongs over the image list with every other image operation's,
/// including the ones the CLI starts.
///
/// Pushing the result to a registry stays a CLI operation — it needs credentials
/// and a target reference, and publishing is an authoring step rather than a way
/// to use the app.
struct SaveImageSheet: View {
    @Bindable var vm: VMManager
    let vmId: String
    let bundlePath: URL
    let onSaveStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(
        vm: VMManager,
        vmId: String,
        bundlePath: URL,
        onSaveStarted: @escaping (String) -> Void
    ) {
        self.vm = vm
        self.vmId = vmId
        self.bundlePath = bundlePath
        self.onSaveStarted = onSaveStarted
        // The VM's own name is the likeliest name for what it becomes, and it is
        // already known to be a legal one.
        _name = State(initialValue: vmId)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The rule a VM id is held to, for the same reason: the name becomes a
    /// directory under `images/`.
    private var nameError: String? {
        VMName.isValid(trimmedName) ? nil : "Use letters, digits, '-' and '_' only."
    }

    /// A name already on this Mac is not refused. Rebuilding an image in place is
    /// the normal way to refresh one — its name is what CI jobs and `image
    /// publish` refer to, and there is no rename — so this becomes a replace, and
    /// `save(replace:)` builds the new copy beside the old one and swaps it in
    /// only once it is complete.
    private var replacing: Bool {
        nameError == nil && vm.imageManager.imageExists(trimmedName)
    }

    /// One image operation at a time, and the manager is shared with the API — a
    /// pull the CLI started while this sheet was open counts.
    private var isBusy: Bool {
        switch vm.imageManager.state {
        case .saving, .pushing, .pulling: true
        case .idle, .completed, .cancelled, .error: false
        }
    }

    /// A running VM's disk is being written to as it is read, so the image would
    /// be a torn copy. The button that opens this sheet is already disabled for
    /// one, but a VM can be started over the API while the sheet is up.
    private var isRunning: Bool {
        vm.vmInstances[vmId]?.state == .running
    }

    private var blockedReason: String? {
        if isRunning { return "\(vmId) is running. Stop it before saving." }
        if isBusy { return "Another image operation is already running." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save as Image")
                .font(.headline)
                .padding(20)

            Divider()

            form

            Divider()

            HStack {
                if let blockedReason {
                    Label(blockedReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Named for what it actually does to an image already there,
                // rather than letting "Save" quietly mean "overwrite".
                Button(replacing ? "Replace" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameError != nil || blockedReason != nil)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                LabeledContent("VM") {
                    Text(vmId)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                TextField("Image Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                if let nameError {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if replacing {
                    // Said before the save rather than after: the old image stays
                    // in `image list` the whole time, so nothing else on screen
                    // reveals that this name was taken.
                    Text("An image named '\(trimmedName)' already exists. The new one is built alongside it and swapped in when complete — a save that fails leaves the old image untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func save() {
        guard nameError == nil, blockedReason == nil else { return }
        let target = trimmedName
        let replace = replacing

        Task { await vm.imageManager.save(name: target, bundlePath: bundlePath, replace: replace) }
        onSaveStarted(target)
        dismiss()
    }
}
