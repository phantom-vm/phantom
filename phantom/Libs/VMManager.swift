import Foundation
import Virtualization

@MainActor
@Observable
class VMManager {

    // MARK: - State

    enum VMState: Equatable {
        case none
        case creating
        case installing(progress: Double)
        case running
        case stopping
        case stopped
        case error(String)
    }

    private(set) var logs: [String] = []

    // MARK: - VM Instance

    struct VMInstance {
        let vmId: String
        let bundlePath: URL
        var state: VMState
        var virtualMachine: VZVirtualMachine?
    }

    struct MountConfig {
        let hostPath: String
        let tag: String
    }

    // MARK: - Private

    private let baseDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("phantom", isDirectory: true)
    }()

    private var vmsDir: URL { baseDir.appendingPathComponent("vms", isDirectory: true) }

    let ipswManager: IPSWManager

    private(set) var vmInstances: [String: VMInstance] = [:]
    private(set) var displayedVMId: String? = nil

    /// Whether an existing installed VM bundle was found on disk
    private(set) var hasExistingVM: Bool = false

    init() {
        let ipswsDir = baseDir.appendingPathComponent("ipsws", isDirectory: true)
        var logFunc: ((String) -> Void)!
        ipswManager = IPSWManager(ipswsDir: ipswsDir, log: { msg in logFunc(msg) })
        logFunc = { [weak self] msg in self?.log(msg) }
        ensureDirectories()
        ipswManager.loadExisting()
        loadExistingVMs()
    }

    // MARK: - Public API

    func createAndStartVM(vmId: String? = nil) async {
        guard let ipswPath = ipswManager.downloadedPath else { return }

        let generatedId = vmId ?? "vm-\(UUID().uuidString.prefix(8).lowercased())"

        // Create VM instance entry
        let bundlePath = vmsDir.appendingPathComponent(generatedId, isDirectory: true)
        vmInstances[generatedId] = VMInstance(
            vmId: generatedId,
            bundlePath: bundlePath,
            state: .creating,
            virtualMachine: nil
        )

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

            try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)

            log("Creating VM bundle at \(generatedId)...")

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
            vmInstances[generatedId]?.virtualMachine = vm

            log("Installing macOS (this will take a while)...")
            vmInstances[generatedId]?.state = .installing(progress: 0)

            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswPath)

            let observation = installer.progress.observe(\.fractionCompleted) { [weak self, generatedId] progress, _ in
                Task { @MainActor in
                    self?.vmInstances[generatedId]?.state = .installing(progress: progress.fractionCompleted)
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
            vmInstances[generatedId]?.state = .running
            log("VM \(generatedId) is running")

        } catch {
            log("VM error: \(error.localizedDescription)")
            vmInstances[generatedId]?.state = .error(error.localizedDescription)
        }
    }

    /// Start an existing VM from a previously installed bundle (no reinstall needed)
    private func startExistingVM(vmId: String, mounts: [MountConfig] = []) async {
        guard let instance = vmInstances[vmId] else {
            log("VM not found: \(vmId)")
            return
        }

        let bundlePath = instance.bundlePath

        // Only start if VM is in stopped, none, or error state
        switch instance.state {
        case .none, .stopped, .error:
            break
        default:
            log("VM \(vmId) cannot be started in current state: \(instance.state.apiString)")
            return
        }

        vmInstances[vmId]?.state = .creating
        log("Loading existing VM from \(vmId)...")

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
                auxiliaryStorage: auxiliaryStorage,
                mounts: mounts
            )

            try config.validate()
            log("VM configuration validated")

            let vm = VZVirtualMachine(configuration: config)
            vmInstances[vmId]?.virtualMachine = vm

            log("Starting VM...")
            try await vm.start()
            vmInstances[vmId]?.state = .running
            log("VM \(vmId) is running")

        } catch {
            log("VM error: \(error.localizedDescription)")
            vmInstances[vmId]?.state = .error(error.localizedDescription)
        }
    }

    func stopVM(vmId: String) async {
        guard let instance = vmInstances[vmId],
              case .running = instance.state,
              let vm = instance.virtualMachine else { return }

        vmInstances[vmId]?.state = .stopping
        log("Stopping VM \(vmId)...")

        do {
            try await vm.stop()
            vmInstances[vmId]?.state = .stopped
            vmInstances[vmId]?.virtualMachine = nil
            log("VM \(vmId) stopped")
        } catch {
            log("Failed to stop VM: \(error.localizedDescription)")
            vmInstances[vmId]?.state = .error(error.localizedDescription)
        }
    }

    func startVM(vmId: String, mounts: [MountConfig] = []) async {
        // Ensure VM exists in dictionary
        if vmInstances[vmId] == nil {
            let bundlePath = vmsDir.appendingPathComponent(vmId)
            guard FileManager.default.fileExists(atPath: bundlePath.path) else {
                log("VM not found: \(vmId)")
                return
            }
            // Add to dictionary
            vmInstances[vmId] = VMInstance(
                vmId: vmId,
                bundlePath: bundlePath,
                state: .stopped,
                virtualMachine: nil
            )
        }

        await startExistingVM(vmId: vmId, mounts: mounts)
    }

    func setDisplayedVM(vmId: String?) {
        displayedVMId = vmId
    }

    func deleteVM(vmId: String) async {
        // Stop VM if running
        if let instance = vmInstances[vmId], case .running = instance.state {
            await stopVM(vmId: vmId)
        }

        guard let instance = vmInstances[vmId] else {
            log("VM not found: \(vmId)")
            return
        }

        do {
            try FileManager.default.removeItem(at: instance.bundlePath)
            log("Deleted VM bundle: \(vmId)")
            vmInstances.removeValue(forKey: vmId)

            // Update hasExistingVM flag
            hasExistingVM = !vmInstances.isEmpty
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
        let stream: Bool?
    }

    struct StreamChunk: Codable {
        let type: String  // "stdout", "stderr", "exit"
        let data: String?
        let exitCode: Int32?
    }

    struct ExecResponse: Codable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    func executeCommand(_ command: String, args: [String]? = nil, vmId: String, waitForAgent: Bool = false) async throws -> ExecResponse {
        guard let instance = vmInstances[vmId],
              case .running = instance.state,
              let vm = instance.virtualMachine else {
            throw PhantomError.vmNotRunning(vmId)
        }

        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw PhantomError.noSocketDevice
        }

        log("Executing on \(vmId): \(command) \(args?.joined(separator: " ") ?? "")")

        // Retry connecting to guest agent (VM may still be booting)
        let maxAttempts = waitForAgent ? 60 : 1
        let retryInterval: UInt64 = 2_000_000_000 // 2 seconds

        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let connection = try await socketDevice.connect(toPort: 9001)
                let fd = connection.fileDescriptor

                let request = ExecRequest(command: command, args: args, stream: nil)
                var requestData = try JSONEncoder().encode(request)
                requestData.append(0x0A) // newline delimiter

                requestData.withUnsafeBytes { ptr in
                    _ = write(fd, ptr.baseAddress!, ptr.count)
                }

                // Read response (newline-delimited JSON)
                let responseData = try await readLine(from: fd)
                let response = try JSONDecoder().decode(ExecResponse.self, from: responseData)

                if !response.stdout.isEmpty {
                    log("stdout: \(response.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
                }
                if !response.stderr.isEmpty {
                    log("stderr: \(response.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
                }
                log("Exit code: \(response.exitCode)")

                connection.close()
                return response
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    if attempt == 1 {
                        log("Waiting for guest agent...")
                    }
                    try await Task.sleep(nanoseconds: retryInterval)
                }
            }
        }

        throw lastError ?? PhantomError.connectionClosed
    }

    func executeCommandStreaming(
        _ command: String,
        args: [String]? = nil,
        vmId: String,
        waitForAgent: Bool = false,
        onChunk: @escaping (StreamChunk) -> Void
    ) async throws -> Int32 {
        guard let instance = vmInstances[vmId],
              case .running = instance.state,
              let vm = instance.virtualMachine else {
            throw PhantomError.vmNotRunning(vmId)
        }

        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw PhantomError.noSocketDevice
        }

        log("Executing (streaming) on \(vmId): \(command)")

        let maxAttempts = waitForAgent ? 60 : 1
        let retryInterval: UInt64 = 2_000_000_000

        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let connection = try await socketDevice.connect(toPort: 9001)
                let fd = connection.fileDescriptor

                let request = ExecRequest(command: command, args: args, stream: true)
                var requestData = try JSONEncoder().encode(request)
                requestData.append(0x0A)

                requestData.withUnsafeBytes { ptr in
                    _ = write(fd, ptr.baseAddress!, ptr.count)
                }

                // Read streaming chunks until we get an "exit" chunk
                let exitCode: Int32 = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global().async {
                        let decoder = JSONDecoder()
                        while true {
                            // Read one line
                            var buffer = Data()
                            var byte: UInt8 = 0
                            while true {
                                let n = read(fd, &byte, 1)
                                if n <= 0 {
                                    cont.resume(throwing: PhantomError.connectionClosed)
                                    return
                                }
                                if byte == 0x0A {
                                    break
                                }
                                buffer.append(byte)
                            }

                            guard let chunk = try? decoder.decode(StreamChunk.self, from: buffer) else {
                                continue
                            }

                            if chunk.type == "exit" {
                                cont.resume(returning: chunk.exitCode ?? -1)
                                return
                            }

                            onChunk(chunk)
                        }
                    }
                }

                connection.close()
                log("Streaming exec finished with exit code: \(exitCode)")
                return exitCode
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    if attempt == 1 {
                        log("Waiting for guest agent...")
                    }
                    try await Task.sleep(nanoseconds: retryInterval)
                }
            }
        }

        throw lastError ?? PhantomError.connectionClosed
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
        try? FileManager.default.createDirectory(at: vmsDir, withIntermediateDirectories: true)
    }

    private func loadExistingVMs() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: vmsDir, includingPropertiesForKeys: nil) else { return }

        for entry in entries {
            let diskPath = entry.appendingPathComponent("disk.img")
            let hwPath = entry.appendingPathComponent("HardwareModel")
            let idPath = entry.appendingPathComponent("MachineIdentifier")
            let auxPath = entry.appendingPathComponent("AuxiliaryStorage")

            if FileManager.default.fileExists(atPath: diskPath.path),
               FileManager.default.fileExists(atPath: hwPath.path),
               FileManager.default.fileExists(atPath: idPath.path),
               FileManager.default.fileExists(atPath: auxPath.path) {
                let vmId = entry.lastPathComponent
                vmInstances[vmId] = VMInstance(
                    vmId: vmId,
                    bundlePath: entry,
                    state: .stopped,
                    virtualMachine: nil
                )
                log("Found existing VM: \(vmId)")
            }
        }

        hasExistingVM = !vmInstances.isEmpty
    }

    private func buildVMConfiguration(
        bundlePath: URL,
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier,
        auxiliaryStorage: VZMacAuxiliaryStorage,
        mounts: [MountConfig] = []
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
        var sharingDevices: [VZVirtioFileSystemDeviceConfiguration] = [fsConfig]

        // Additional per-VM mounts
        for mount in mounts {
            let url = URL(fileURLWithPath: mount.hostPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PhantomError.mountPathNotFound(mount.hostPath)
            }
            let dir = VZSharedDirectory(url: url, readOnly: false)
            let mountShare = VZSingleDirectoryShare(directory: dir)
            let mountConfig = VZVirtioFileSystemDeviceConfiguration(tag: mount.tag)
            mountConfig.share = mountShare
            sharingDevices.append(mountConfig)
            log("Mounting \(mount.hostPath) as '\(mount.tag)'")
        }

        config.directorySharingDevices = sharingDevices

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

    func listVMs() -> [VMInfo] {
        return vmInstances.values.map { instance in
            VMInfo(
                id: instance.vmId,
                path: instance.bundlePath.path,
                state: instance.state.apiString
            )
        }.sorted { $0.id < $1.id }
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
    case vmNotRunning(String)
    case noSocketDevice
    case connectionClosed
    case mountPathNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware: "This Mac doesn't support the restore image's hardware requirements"
        case .diskCreationFailed: "Failed to create disk image"
        case .vmBundleCorrupted: "VM bundle is missing required files"
        case .vmNotFound(let id): "VM not found: \(id)"
        case .cloneFailed(let message): message
        case .vmNotRunning(let id): "VM is not running: \(id)"
        case .noSocketDevice: "No vsock device available"
        case .connectionClosed: "Connection to guest agent closed"
        case .mountPathNotFound(let path): "Mount path not found: \(path)"
        }
    }
}

