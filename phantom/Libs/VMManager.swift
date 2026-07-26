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
        case restoring(progress: Double)
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

    // MARK: - Private

    private let baseDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("phantom", isDirectory: true)
    }()

    private var vmsDir: URL { baseDir.appendingPathComponent("vms", isDirectory: true) }

    let ipswManager: IPSWManager
    let imageManager: OCIImageManager
    let catalogManager: CatalogManager
    let gitlabRunnerManager: GitLabRunnerManager

    private(set) var vmInstances: [String: VMInstance] = [:]
    private(set) var vncServers: [String: VNCServer] = [:]
    private(set) var displayedVMId: String? = nil
    private(set) var displayRequestCounter: Int = 0

    /// Whether an existing installed VM bundle was found on disk
    private(set) var hasExistingVM: Bool = false

    init() {
        let ipswsDir = baseDir.appendingPathComponent("ipsws", isDirectory: true)
        let imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        let runnerDir = baseDir.appendingPathComponent("gitlab-runner", isDirectory: true)
        var logFunc: ((String) -> Void)!
        ipswManager = IPSWManager(ipswsDir: ipswsDir, log: { msg in logFunc(msg) })
        imageManager = OCIImageManager(imagesDir: imagesDir, log: { msg in logFunc(msg) })
        catalogManager = CatalogManager(log: { msg in logFunc(msg) })
        gitlabRunnerManager = GitLabRunnerManager(runnerDir: runnerDir, log: { msg in logFunc(msg) })
        logFunc = { [weak self] msg in self?.log(msg) }
        ensureDirectories()
        ipswManager.loadExisting()
        loadExistingVMs()
        // Not under test: the runner is a long-lived child process, so starting
        // it from a test host both fights the real daemon's runner and keeps the
        // host alive after the tests finish, which xcodebuild waits out.
        if !ProcessInfo.processInfo.isRunningTests {
            Task { await gitlabRunnerManager.autostart() }
        }
    }

    // MARK: - Public API

    func createAndStartVM(vmId: String? = nil, ipswId: String? = nil, settings: VMSettings? = nil) async {
        // The API always names an IPSW; only the GUI's "Create & Start VM"
        // button (no picker) falls back to whichever download exists.
        let ipswPath: URL
        if let ipswId {
            guard let info = ipswManager.list().first(where: { $0.id == ipswId }) else {
                log("IPSW not found: \(ipswId)")
                return
            }
            ipswPath = URL(fileURLWithPath: info.path)
        } else if let fallback = ipswManager.downloadedPath {
            ipswPath = fallback
        } else {
            return
        }

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

            // Written before the configuration is built, since that is what
            // reads it back.
            try (settings ?? .defaults).clamped().write(to: bundlePath)

            // Disk image — 90GB sparse
            let diskPath = bundlePath.appendingPathComponent("disk.img")
            try createDiskImage(at: diskPath, sizeGB: 90)

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

            let observation = installer.progress.observe(\.fractionCompleted) { progress, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.vmInstances[generatedId]?.state = .installing(progress: progress.fractionCompleted)
                    if Int(progress.fractionCompleted * 100) % 10 == 0 {
                        self.log("Installation progress: \(Int(progress.fractionCompleted * 100))%")
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

            // The VZMacOSInstaller's own VM instance doesn't reliably boot into
            // Setup Assistant — it often hangs on a black screen. Tear it down
            // and boot a fresh VZVirtualMachine from the installed bundle
            // instead; a clean restart reaches Setup Assistant every time. The
            // grace period lets Virtualization.framework finalize the install
            // before we reopen the disk (cf. tart's create_grace_time).
            vmInstances[generatedId]?.virtualMachine = nil
            vmInstances[generatedId]?.state = .stopped
            log("Finalizing install, restarting VM cleanly...")
            try await Task.sleep(nanoseconds: 10_000_000_000)
            await startExistingVM(vmId: generatedId)

        } catch {
            log("VM error: \(error.localizedDescription)")
            vmInstances[generatedId]?.state = .error(error.localizedDescription)
        }
    }

    /// Start an existing VM from a previously installed bundle (no reinstall needed)
    private func startExistingVM(vmId: String) async {
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
                auxiliaryStorage: auxiliaryStorage
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

        stopVNC(vmId: vmId)

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

    func startVM(vmId: String) async {
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

        await startExistingVM(vmId: vmId)
    }

    // MARK: - VNC

    /// Starts a VNC server for a running VM (or returns the existing one).
    /// Returns a `vnc://:password@127.0.0.1:port` URL.
    func startVNC(vmId: String) async throws -> String {
        guard let instance = vmInstances[vmId],
              case .running = instance.state,
              let vm = instance.virtualMachine else {
            throw PhantomError.vmNotRunning(vmId)
        }

        if let existing = vncServers[vmId], let url = existing.url {
            return url
        }

        let server = try VNCServer(virtualMachine: vm)
        vncServers[vmId] = server
        do {
            let url = try await server.start()
            log("VNC server for \(vmId): \(url)")
            return url
        } catch {
            vncServers.removeValue(forKey: vmId)
            throw error
        }
    }

    func stopVNC(vmId: String) {
        if let server = vncServers.removeValue(forKey: vmId) {
            server.stop()
            log("VNC server for \(vmId) stopped")
        }
    }

    /// Captures the VM's current screen to a PNG. Starts a VNC server if needed.
    /// Returns the file path written. Useful for authoring/debugging boot scripts.
    func captureScreenshot(vmId: String, outputPath: String?) async throws -> String {
        _ = try await startVNC(vmId: vmId)
        guard let vnc = vncServers[vmId] else {
            throw PhantomError.vmNotRunning(vmId)
        }
        let port = vnc.port
        let password = vnc.password

        let destination: String
        if let outputPath {
            destination = (outputPath as NSString).expandingTildeInPath
        } else {
            destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-\(vmId)-\(Int(Date().timeIntervalSince1970)).png").path
        }

        try await Task.detached {
            let client = try RFBClient(port: port, password: password)
            let image = try client.captureFramebuffer()
            try RFBClient.writePNG(image, to: destination)
        }.value

        log("Screenshot of \(vmId) saved to \(destination)")
        return destination
    }

    // MARK: - Boot Script

    enum BootScriptState: Equatable {
        case idle
        case running(message: String)
        case completed
        case error(String)
    }

    private(set) var bootScriptStates: [String: BootScriptState] = [:]

    /// Starts executing boot commands against the VM via VNC keystroke
    /// injection. Runs in the background; poll `bootScriptStates` for progress.
    func runBootScript(vmId: String, commands: [String]) async throws {
        guard let instance = vmInstances[vmId],
              case .running = instance.state,
              instance.virtualMachine != nil else {
            throw PhantomError.vmNotRunning(vmId)
        }
        if case .running = bootScriptStates[vmId] {
            throw PhantomError.bootScriptBusy(vmId)
        }

        // Validate the DSL upfront so typos fail the API call, not the background task
        _ = try BootCommand.parse(commands: commands)

        _ = try await startVNC(vmId: vmId)
        guard let vnc = vncServers[vmId] else {
            throw PhantomError.vmNotRunning(vmId)
        }
        let port = vnc.port
        let password = vnc.password

        bootScriptStates[vmId] = .running(message: "connecting")
        log("Boot script started on \(vmId) (\(commands.count) commands)")

        let manager = self
        Task.detached {
            let report: @Sendable (BootScriptState, String) -> Void = { state, logMessage in
                Task { @MainActor in
                    manager.bootScriptStates[vmId] = state
                    manager.log(logMessage)
                }
            }

            do {
                let runner = try BootScriptRunner(vncPort: port, vncPassword: password) { message in
                    report(.running(message: message), "bootScript[\(vmId)]: \(message)")
                }
                try await runner.run(commands: commands)
                report(.completed, "Boot script completed on \(vmId)")
            } catch {
                report(.error(error.localizedDescription), "Boot script failed on \(vmId): \(error.localizedDescription)")
            }
        }
    }

    func setDisplayedVM(vmId: String?) {
        displayedVMId = vmId
    }

    func requestDisplay(vmId: String) {
        displayedVMId = vmId
        displayRequestCounter += 1
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

        // A VM whose restore failed has no bundle left — unregister it anyway,
        // otherwise the failed entry is stuck in `vm list` until the daemon
        // restarts, with no way to clear it.
        if FileManager.default.fileExists(atPath: instance.bundlePath.path) {
            do {
                try FileManager.default.removeItem(at: instance.bundlePath)
                log("Deleted VM bundle: \(vmId)")
            } catch {
                log("Failed to delete VM: \(error.localizedDescription)")
                return
            }
        }

        vmInstances.removeValue(forKey: vmId)
        hasExistingVM = !vmInstances.isEmpty
    }

    func cloneVM(
        sourceVmId: String,
        vmId requestedId: String? = nil,
        settings: VMSettings? = nil
    ) async throws -> String {
        if let requestedId, vmInstances[requestedId] != nil {
            throw PhantomError.vmAlreadyExists(requestedId)
        }

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
        let cloneVmId = requestedId ?? "vm-\(UUID().uuidString.prefix(8).lowercased())"
        let cloneBundle = vmsDir.appendingPathComponent(cloneVmId, isDirectory: true)
        try FileManager.default.createDirectory(at: cloneBundle, withIntermediateDirectories: true)

        log("Cloning VM \(sourceVmId) to \(cloneVmId)...")

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

        // Without an explicit size, carry the source's over — a clone that
        // quietly reverted to the defaults would be a different machine than
        // the one it was cloned from.
        try? (settings ?? VMSettings.load(from: sourceBundle)).clamped().write(to: cloneBundle)

        // Generate new MachineIdentifier (required for unique VM identity)
        let newMachineIdentifier = VZMacMachineIdentifier()
        let cloneIdPath = cloneBundle.appendingPathComponent("MachineIdentifier")
        try newMachineIdentifier.dataRepresentation.write(to: cloneIdPath)
        log("Generated new machine identifier")

        log("Clone complete: \(cloneVmId)")
        return cloneVmId
    }

    // MARK: - Create from Image

    /// Restores a VM bundle from a local image and boots it, in the background.
    ///
    /// Returns as soon as the image is known to exist, so the caller gets a vmId
    /// after a few milliseconds instead of after a 90GB decompression. The
    /// instance is registered *before* the restore starts, so the VM is in
    /// `vm.list` (as `restoring(N%)`, then `running`) the whole way through — a
    /// caller that times out or disconnects mid-restore can still find it, and
    /// the bundle can't sit unregistered until the next daemon start.
    ///
    /// Progress lives on the VM's own state rather than `imageManager.state`:
    /// that slot is single-occupancy and would make a restore and a concurrent
    /// pull overwrite each other's progress.
    func createVMFromImage(
        imageName: String,
        vmId requestedId: String? = nil,
        settings: VMSettings? = nil
    ) throws -> String {
        guard imageManager.imageExists(imageName) else {
            throw OCIError.imageNotFound(imageName)
        }

        let vmId = requestedId ?? "vm-\(UUID().uuidString.prefix(8).lowercased())"
        guard vmInstances[vmId] == nil else {
            throw PhantomError.vmAlreadyExists(vmId)
        }
        let bundlePath = vmsDir.appendingPathComponent(vmId, isDirectory: true)
        vmInstances[vmId] = VMInstance(
            vmId: vmId,
            bundlePath: bundlePath,
            state: .restoring(progress: 0),
            virtualMachine: nil
        )
        hasExistingVM = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.imageManager.restore(
                    image: imageName,
                    into: bundlePath,
                    progress: { progress in
                        Task { @MainActor [weak self] in
                            self?.vmInstances[vmId]?.state = .restoring(progress: progress)
                        }
                    }
                )
                // After the restore: it creates the bundle, and cleans it up
                // again if it fails, so anything written earlier would be lost.
                try (settings ?? .defaults).clamped().write(to: bundlePath)
                self.vmInstances[vmId]?.state = .stopped
                await self.startExistingVM(vmId: vmId)
            } catch {
                self.log("Failed to create VM from image '\(imageName)': \(error.localizedDescription)")
                // The bundle is gone (restore cleans up after itself), but the
                // instance stays so a poller learns why instead of watching the
                // VM vanish. `vm delete` clears it.
                self.vmInstances[vmId]?.state = .error(error.localizedDescription)
            }
        }

        return vmId
    }

    // MARK: - Guest Command Execution

    struct ExecRequest: Codable {
        let command: String
        let args: [String]?
        let stream: Bool?
    }

    nonisolated struct StreamChunk: Codable, Sendable {
        let type: String  // "stdout", "stderr", "exit"
        let data: String?
        let exitCode: Int32?
    }

    nonisolated struct ExecResponse: Codable, Sendable {
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

                            // Try to decode as streaming chunk
                            if let chunk = try? decoder.decode(StreamChunk.self, from: buffer) {
                                if chunk.type == "exit" {
                                    cont.resume(returning: chunk.exitCode ?? -1)
                                    return
                                }
                                onChunk(chunk)
                                continue
                            }

                            // Fallback: agent sent a batch ExecResponse (old agent without streaming)
                            if let batch = try? decoder.decode(ExecResponse.self, from: buffer) {
                                // Forward stdout/stderr as chunks, then exit
                                if !batch.stderr.isEmpty {
                                    onChunk(StreamChunk(type: "stderr", data: batch.stderr, exitCode: nil))
                                }
                                if !batch.stdout.isEmpty {
                                    onChunk(StreamChunk(type: "stdout", data: batch.stdout, exitCode: nil))
                                }
                                cont.resume(returning: batch.exitCode)
                                return
                            }

                            print("VMManager: failed to decode stream chunk: \(String(data: buffer, encoding: .utf8) ?? "<binary>")")
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
        auxiliaryStorage: VZMacAuxiliaryStorage
    ) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        config.platform = createPlatform(
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            auxiliaryStorage: auxiliaryStorage
        )
        config.bootLoader = VZMacOSBootLoader()

        // Read on every start, not just at create: this is what makes a VM
        // sized at creation keep that size across reboots.
        let settings = VMSettings.load(from: bundlePath).clamped()
        config.cpuCount = settings.cpuCount
        config.memorySize = settings.memorySize

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

        // No directory sharing devices: everything the guest needs arrives
        // over the network or vsock, and a host share exposed read-write to a
        // CI VM running untrusted code would be a hole.

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
        case .restoring(let progress): return "restoring(\(Int(progress * 100))%)"
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
    case vmAlreadyExists(String)
    case cloneFailed(String)
    case vmNotRunning(String)
    case noSocketDevice
    case connectionClosed
    case bootScriptBusy(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware: "This Mac doesn't support the restore image's hardware requirements"
        case .diskCreationFailed: "Failed to create disk image"
        case .vmBundleCorrupted: "VM bundle is missing required files"
        case .vmNotFound(let id): "VM not found: \(id)"
        case .vmAlreadyExists(let id): "A VM named '\(id)' already exists"
        case .cloneFailed(let message): message
        case .vmNotRunning(let id): "VM is not running: \(id)"
        case .noSocketDevice: "No vsock device available"
        case .connectionClosed: "Connection to guest agent closed"
        case .bootScriptBusy(let id): "A boot script is already running on VM: \(id)"
        }
    }
}


// MARK: - Test Environment

extension ProcessInfo {
    /// True when this process is hosting an XCTest bundle.
    ///
    /// The unit tests exercise pure logic (chunking, references, types) and get
    /// the app only because `@testable import` needs it as a host. The daemon's
    /// side effects — binding the API port, supervising the GitLab runner — must
    /// stay off in that case: both collide with an already-running daemon, and
    /// either one keeps the host process alive past the end of the tests, which
    /// xcodebuild reports as the run never finishing.
    var isRunningTests: Bool { environment["XCTestConfigurationFilePath"] != nil }
}
