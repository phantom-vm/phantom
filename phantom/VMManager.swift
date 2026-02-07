import Foundation
import Virtualization

@MainActor
@Observable
class VMManager {

    // MARK: - State

    enum ImageState: Equatable {
        case none
        case fetching
        case downloading(progress: Double)
        case downloaded(path: URL)
        case error(String)

        static func == (lhs: ImageState, rhs: ImageState) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.fetching, .fetching): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.downloaded(let a), .downloaded(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    enum VMState: Equatable {
        case none
        case creating
        case installing(progress: Double)
        case running
        case stopping
        case stopped
        case error(String)
    }

    private(set) var imageState: ImageState = .none
    private(set) var vmState: VMState = .none
    private(set) var imageInfo: String = ""
    private(set) var logs: [String] = []

    // MARK: - Private

    private let baseDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("phantom", isDirectory: true)
    }()

    private var imagesDir: URL { baseDir.appendingPathComponent("images", isDirectory: true) }
    private var vmsDir: URL { baseDir.appendingPathComponent("vms", isDirectory: true) }

    private(set) var virtualMachine: VZVirtualMachine?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private(set) var currentBundlePath: URL?

    /// Whether an existing installed VM bundle was found on disk
    private(set) var hasExistingVM: Bool = false

    init() {
        ensureDirectories()
        checkExistingImage()
        checkExistingVM()
    }

    // MARK: - Public API

    func downloadImage() async {
        guard imageState == .none || {
            if case .error = imageState { return true }
            return false
        }() else { return }

        log("Fetching latest macOS restore image info...")
        imageState = .fetching

        do {
            let restoreImage = try await VZMacOSRestoreImage.latestSupported
            let buildVersion = restoreImage.buildVersion
            let url = restoreImage.url

            log("Found: macOS build \(buildVersion)")
            log("Download URL: \(url)")
            imageInfo = "macOS build \(buildVersion)"

            let destination = imagesDir.appendingPathComponent("\(buildVersion).ipsw")

            if FileManager.default.fileExists(atPath: destination.path) {
                log("Image already downloaded at \(destination.path)")
                imageState = .downloaded(path: destination)
                return
            }

            log("Starting download...")
            imageState = .downloading(progress: 0)

            let delegate = DownloadDelegate(
                destination: destination,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.imageState = .downloading(progress: progress)
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        switch result {
                        case .success(let path):
                            self.log("Image saved to \(path.path)")
                            self.imageState = .downloaded(path: path)
                        case .failure(let error):
                            self.log("Download failed: \(error.localizedDescription)")
                            self.imageState = .error(error.localizedDescription)
                        }
                    }
                }
            )
            self.downloadDelegate = delegate

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        } catch {
            log("Failed to fetch image info: \(error.localizedDescription)")
            imageState = .error(error.localizedDescription)
        }
    }

    func createAndStartVM() async {
        guard case .downloaded(let ipswPath) = imageState else { return }
        guard vmState == .none || vmState == .stopped || {
            if case .error = vmState { return true }
            return false
        }() else { return }

        vmState = .creating
        log("Loading restore image from \(ipswPath.lastPathComponent)...")

        do {
            let restoreImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VZMacOSRestoreImage, Error>) in
                VZMacOSRestoreImage.load(from: ipswPath) { result in
                    cont.resume(with: result)
                }
            }

            guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
                throw PhantomError.unsupportedHardware
            }

            let vmID = UUID().uuidString.prefix(8).lowercased()
            let bundlePath = vmsDir.appendingPathComponent("vm-\(vmID)", isDirectory: true)
            try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
            currentBundlePath = bundlePath

            log("Creating VM bundle at \(bundlePath.lastPathComponent)...")

            // Disk image — 64GB sparse
            let diskPath = bundlePath.appendingPathComponent("disk.img")
            try createDiskImage(at: diskPath, sizeGB: 64)

            // Auxiliary storage
            let auxPath = bundlePath.appendingPathComponent("AuxiliaryStorage")
            let auxStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxPath,
                hardwareModel: requirements.hardwareModel,
                options: [.allowOverwrite]
            )

            // Machine identifier
            let machineIdentifier = VZMacMachineIdentifier()
            let idPath = bundlePath.appendingPathComponent("MachineIdentifier")
            try machineIdentifier.dataRepresentation.write(to: idPath)

            // Hardware model
            let hwPath = bundlePath.appendingPathComponent("HardwareModel")
            try requirements.hardwareModel.dataRepresentation.write(to: hwPath)

            // Configure VM
            let config = try buildVMConfiguration(
                bundlePath: bundlePath,
                hardwareModel: requirements.hardwareModel,
                machineIdentifier: machineIdentifier,
                auxiliaryStorage: auxStorage
            )

            try config.validate()
            log("VM configuration validated")

            // Create and install
            let vm = VZVirtualMachine(configuration: config)
            self.virtualMachine = vm

            log("Installing macOS (this will take a while)...")
            vmState = .installing(progress: 0)

            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswPath)

            let observation = installer.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.vmState = .installing(progress: progress.fractionCompleted)
                    if Int(progress.fractionCompleted * 100) % 10 == 0 {
                        self?.log("Installation progress: \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            }

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                installer.install { result in
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }

            _ = observation // keep alive until install completes

            log("Installation complete!")
            hasExistingVM = true
            if vm.state == .stopped {
                log("Starting VM...")
                try await vm.start()
            }
            vmState = .running
            log("VM is running")

        } catch {
            log("VM error: \(error.localizedDescription)")
            vmState = .error(error.localizedDescription)
        }
    }

    /// Start an existing VM from a previously installed bundle (no reinstall needed)
    func startExistingVM() async {
        guard let bundlePath = currentBundlePath else {
            log("No existing VM bundle found")
            return
        }
        guard vmState == .none || vmState == .stopped || {
            if case .error = vmState { return true }
            return false
        }() else { return }

        vmState = .creating
        log("Loading existing VM from \(bundlePath.lastPathComponent)...")

        do {
            let hwPath = bundlePath.appendingPathComponent("HardwareModel")
            let idPath = bundlePath.appendingPathComponent("MachineIdentifier")
            let auxPath = bundlePath.appendingPathComponent("AuxiliaryStorage")

            guard FileManager.default.fileExists(atPath: hwPath.path),
                  FileManager.default.fileExists(atPath: idPath.path),
                  FileManager.default.fileExists(atPath: auxPath.path) else {
                throw PhantomError.vmBundleCorrupted
            }

            let hwData = try Data(contentsOf: hwPath)
            guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hwData) else {
                throw PhantomError.vmBundleCorrupted
            }

            let idData = try Data(contentsOf: idPath)
            guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
                throw PhantomError.vmBundleCorrupted
            }

            let auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxPath)

            let config = try buildVMConfiguration(
                bundlePath: bundlePath,
                hardwareModel: hardwareModel,
                machineIdentifier: machineIdentifier,
                auxiliaryStorage: auxiliaryStorage
            )

            try config.validate()
            log("VM configuration validated")

            let vm = VZVirtualMachine(configuration: config)
            self.virtualMachine = vm

            log("Starting VM...")
            try await vm.start()
            vmState = .running
            log("VM is running")

        } catch {
            log("VM error: \(error.localizedDescription)")
            vmState = .error(error.localizedDescription)
        }
    }

    func stopVM() async {
        guard vmState == .running, let vm = virtualMachine else { return }

        vmState = .stopping
        log("Stopping VM...")

        do {
            try await vm.stop()
            vmState = .stopped
            virtualMachine = nil
            log("VM stopped")
        } catch {
            log("Failed to stop VM: \(error.localizedDescription)")
            vmState = .error(error.localizedDescription)
        }
    }

    func deleteVM() async {
        if vmState == .running {
            await stopVM()
        }

        guard let bundlePath = currentBundlePath else {
            log("No VM bundle to delete")
            return
        }

        do {
            try FileManager.default.removeItem(at: bundlePath)
            log("Deleted VM bundle: \(bundlePath.lastPathComponent)")
            currentBundlePath = nil
            virtualMachine = nil
            hasExistingVM = false
            vmState = .none
        } catch {
            log("Failed to delete VM: \(error.localizedDescription)")
        }
    }

    func startVM(vmId: String) async {
        // Stop current VM if running
        if vmState == .running {
            await stopVM()
        }

        // Set the bundle path to the specified VM
        let bundlePath = vmsDir.appendingPathComponent(vmId)
        guard FileManager.default.fileExists(atPath: bundlePath.path) else {
            log("VM not found: \(vmId)")
            vmState = .error("VM not found: \(vmId)")
            return
        }

        currentBundlePath = bundlePath
        await startExistingVM()
    }

    func deleteVM(vmId: String) async {
        // If deleting the current VM, use the existing deleteVM logic
        if currentBundlePath?.lastPathComponent == vmId {
            await deleteVM()
            return
        }

        // Delete a different VM
        let bundlePath = vmsDir.appendingPathComponent(vmId)
        guard FileManager.default.fileExists(atPath: bundlePath.path) else {
            log("VM not found: \(vmId)")
            return
        }

        do {
            try FileManager.default.removeItem(at: bundlePath)
            log("Deleted VM bundle: \(vmId)")
        } catch {
            log("Failed to delete VM: \(error.localizedDescription)")
        }
    }

    func cloneVM(sourceVmId: String) async throws -> String {
        // Find source VM bundle
        let sourceBundle = vmsDir.appendingPathComponent(sourceVmId)
        guard FileManager.default.fileExists(atPath: sourceBundle.path) else {
            throw PhantomError.vmNotFound(sourceVmId)
        }

        // Verify source VM has all required files
        let sourceDiskPath = sourceBundle.appendingPathComponent("disk.img")
        let sourceHwPath = sourceBundle.appendingPathComponent("HardwareModel")
        let sourceAuxPath = sourceBundle.appendingPathComponent("AuxiliaryStorage")

        guard FileManager.default.fileExists(atPath: sourceDiskPath.path),
              FileManager.default.fileExists(atPath: sourceHwPath.path),
              FileManager.default.fileExists(atPath: sourceAuxPath.path) else {
            throw PhantomError.vmBundleCorrupted
        }

        // Create new VM bundle
        let cloneId = UUID().uuidString.prefix(8).lowercased()
        let cloneBundle = vmsDir.appendingPathComponent("vm-\(cloneId)", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneBundle, withIntermediateDirectories: true)

        log("Cloning VM \(sourceVmId) to vm-\(cloneId)...")

        // Clone disk image using APFS copy-on-write (clonefile syscall)
        let cloneDiskPath = cloneBundle.appendingPathComponent("disk.img")
        let cloneResult = clonefile(sourceDiskPath.path, cloneDiskPath.path, 0)
        guard cloneResult == 0 else {
            try? FileManager.default.removeItem(at: cloneBundle)
            throw PhantomError.cloneFailed("Failed to clone disk image")
        }
        log("Cloned disk image (APFS CoW)")

        // Copy AuxiliaryStorage
        let cloneAuxPath = cloneBundle.appendingPathComponent("AuxiliaryStorage")
        try FileManager.default.copyItem(at: sourceAuxPath, to: cloneAuxPath)
        log("Copied auxiliary storage")

        // Copy HardwareModel
        let cloneHwPath = cloneBundle.appendingPathComponent("HardwareModel")
        try FileManager.default.copyItem(at: sourceHwPath, to: cloneHwPath)

        // Generate new MachineIdentifier (required for unique VM identity)
        let newMachineIdentifier = VZMacMachineIdentifier()
        let cloneIdPath = cloneBundle.appendingPathComponent("MachineIdentifier")
        try newMachineIdentifier.dataRepresentation.write(to: cloneIdPath)
        log("Generated new machine identifier")

        log("Clone complete: vm-\(cloneId)")
        return "vm-\(cloneId)"
    }

    // MARK: - Guest Command Execution

    struct ExecRequest: Codable {
        let command: String
        let args: [String]?
    }

    struct ExecResponse: Codable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private(set) var lastExecResult: ExecResponse?

    func executeCommand(_ command: String, args: [String]? = nil) async {
        guard vmState == .running, let vm = virtualMachine else {
            log("Cannot execute command: VM not running")
            return
        }

        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            log("Cannot execute command: no vsock device")
            return
        }

        log("Executing: \(command) \(args?.joined(separator: " ") ?? "")")

        do {
            let connection = try await socketDevice.connect(toPort: 9001)
            let fd = connection.fileDescriptor

            let request = ExecRequest(command: command, args: args)
            var requestData = try JSONEncoder().encode(request)
            requestData.append(0x0A) // newline delimiter

            requestData.withUnsafeBytes { ptr in
                _ = write(fd, ptr.baseAddress!, ptr.count)
            }

            // Read response (newline-delimited JSON)
            let responseData = try await readLine(from: fd)

            let response = try JSONDecoder().decode(ExecResponse.self, from: responseData)
            lastExecResult = response

            if !response.stdout.isEmpty {
                log("stdout: \(response.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
            }
            if !response.stderr.isEmpty {
                log("stderr: \(response.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
            }
            log("Exit code: \(response.exitCode)")

            connection.close()
        } catch {
            log("Exec failed: \(error.localizedDescription)")
        }
    }

    private func readLine(from fd: Int32) async throws -> Data {
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var buffer = Data()
                var byte: UInt8 = 0
                while true {
                    let n = read(fd, &byte, 1)
                    if n <= 0 {
                        cont.resume(throwing: PhantomError.connectionClosed)
                        return
                    }
                    if byte == 0x0A {
                        cont.resume(returning: buffer)
                        return
                    }
                    buffer.append(byte)
                }
            }
        }
    }

    // MARK: - Helpers

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vmsDir, withIntermediateDirectories: true)
    }

    private func checkExistingImage() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil),
              let ipsw = files.first(where: { $0.pathExtension == "ipsw" }) else { return }
        imageState = .downloaded(path: ipsw)
        imageInfo = ipsw.deletingPathExtension().lastPathComponent
        log("Found existing image: \(ipsw.lastPathComponent)")
    }

    private func checkExistingVM() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: vmsDir, includingPropertiesForKeys: nil) else { return }
        // Find first VM bundle that has all required files (installed successfully)
        for entry in entries {
            let diskPath = entry.appendingPathComponent("disk.img")
            let hwPath = entry.appendingPathComponent("HardwareModel")
            let idPath = entry.appendingPathComponent("MachineIdentifier")
            let auxPath = entry.appendingPathComponent("AuxiliaryStorage")
            if FileManager.default.fileExists(atPath: diskPath.path),
               FileManager.default.fileExists(atPath: hwPath.path),
               FileManager.default.fileExists(atPath: idPath.path),
               FileManager.default.fileExists(atPath: auxPath.path) {
                currentBundlePath = entry
                hasExistingVM = true
                vmState = .stopped
                log("Found existing VM: \(entry.lastPathComponent)")
                return
            }
        }
    }

    private func buildVMConfiguration(
        bundlePath: URL,
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier,
        auxiliaryStorage: VZMacAuxiliaryStorage
    ) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        config.platform = createPlatform(
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            auxiliaryStorage: auxiliaryStorage
        )
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, 4)
        config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, 8 * 1024 * 1024 * 1024)

        let diskPath = bundlePath.appendingPathComponent("disk.img")
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskPath, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)
        ]
        config.graphicsDevices = [graphics]

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Vsock for host-guest communication
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Shared directory (host → guest) - common across all VMs
        let sharedDir = baseDir.appendingPathComponent("shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedDir, readOnly: false))
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "phantom-shared")
        fsConfig.share = share
        config.directorySharingDevices = [fsConfig]

        return config
    }

    private func createDiskImage(at url: URL, sizeGB: Int) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PhantomError.diskCreationFailed }
        let size = Int64(sizeGB) * 1024 * 1024 * 1024
        let ret = ftruncate(fd, off_t(size))
        close(fd)
        guard ret == 0 else { throw PhantomError.diskCreationFailed }
        log("Created \(sizeGB)GB disk image")
    }

    private func createPlatform(
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier,
        auxiliaryStorage: VZMacAuxiliaryStorage
    ) -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxiliaryStorage
        return platform
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
    }

    // MARK: - API Support

    func listImages() -> [ImageInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imagesDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return []
        }

        return files.filter { $0.pathExtension == "ipsw" }.compactMap { url in
            guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = resourceValues.fileSize else {
                return nil
            }
            return ImageInfo(
                id: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                size: size
            )
        }
    }

    func listVMs() -> [VMInfo] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: vmsDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return entries.compactMap { entry in
            let diskPath = entry.appendingPathComponent("disk.img")
            guard FileManager.default.fileExists(atPath: diskPath.path) else {
                return nil
            }

            let state: String
            if entry == currentBundlePath {
                state = vmState.apiString
            } else {
                state = "stopped"
            }

            return VMInfo(
                id: entry.lastPathComponent,
                path: entry.path,
                state: state
            )
        }
    }
}

// MARK: - VMState API Extension

extension VMManager.VMState {
    var apiString: String {
        switch self {
        case .none: return "none"
        case .creating: return "creating"
        case .installing(let progress): return "installing(\(Int(progress * 100))%)"
        case .running: return "running"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .error(let message): return "error: \(message)"
        }
    }
}

// MARK: - Errors

enum PhantomError: LocalizedError {
    case unsupportedHardware
    case diskCreationFailed
    case vmBundleCorrupted
    case vmNotFound(String)
    case cloneFailed(String)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware: "This Mac doesn't support the restore image's hardware requirements"
        case .diskCreationFailed: "Failed to create disk image"
        case .vmBundleCorrupted: "VM bundle is missing required files"
        case .vmNotFound(let id): "VM not found: \(id)"
        case .cloneFailed(let message): message
        case .connectionClosed: "Connection to guest agent closed"
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let onProgress: (Double) -> Void
    let onComplete: (Result<URL, Error>) -> Void

    init(destination: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            onComplete(.success(destination))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }
}
