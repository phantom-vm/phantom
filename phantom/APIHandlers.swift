import Foundation

@MainActor
struct APIHandlers {
    let vmManager: VMManager

    func handleStream(_ request: APIRequest, sendChunk: @escaping (Data) -> Void) async {
        guard let vmId = request.params?["vmId"]?.value as? String else {
            let error = try? JSONEncoder().encode(StreamDoneChunk(type: "done", exitCode: -1, error: "Missing vmId"))
            if let error { sendChunk(error) }
            return
        }
        guard let command = request.params?["command"]?.value as? String else {
            let error = try? JSONEncoder().encode(StreamDoneChunk(type: "done", exitCode: -1, error: "Missing command"))
            if let error { sendChunk(error) }
            return
        }
        let user = request.params?["user"]?.value as? String
        let (wrappedCommand, args) = applyUser(
            command: command,
            args: request.params?["args"]?.value as? [String],
            user: user
        )
        let waitForAgent = (request.params?["waitForAgent"]?.value as? Bool) ?? false

        do {
            let exitCode = try await vmManager.executeCommandStreaming(
                wrappedCommand,
                args: args,
                vmId: vmId,
                waitForAgent: waitForAgent
            ) { chunk in
                if let data = try? JSONEncoder().encode(chunk) {
                    sendChunk(data)
                }
            }
            let done = try JSONEncoder().encode(StreamDoneChunk(type: "done", exitCode: exitCode, error: nil))
            sendChunk(done)
        } catch {
            let done = try? JSONEncoder().encode(StreamDoneChunk(type: "done", exitCode: -1, error: error.localizedDescription))
            if let done { sendChunk(done) }
        }
    }

    func handle(_ request: APIRequest) async -> Data {
        do {
            let result = try await route(request)
            let response = APIResponse(result: result, error: nil)
            return try JSONEncoder().encode(response)
        } catch let error as APIHandlerError {
            let apiError = APIError(code: error.code, message: error.message)
            let response = APIResponse(result: nil, error: apiError)
            return (try? JSONEncoder().encode(response)) ?? Data()
        } catch {
            let apiError = APIError(code: "handler_error", message: error.localizedDescription)
            let response = APIResponse(result: nil, error: apiError)
            return (try? JSONEncoder().encode(response)) ?? Data()
        }
    }

    private func route(_ request: APIRequest) async throws -> AnyCodable {
        switch request.method {
        case "health":
            return try await handleHealth()
        case "ipsw.list":
            return try await handleIpswList()
        case "ipsw.pull":
            return try await handleIpswPull()
        case "ipsw.status":
            return try await handleIpswStatus()
        case "vm.list":
            return try await handleVmsList()
        case "vm.create":
            return try await handleVmsCreate(params: request.params)
        case "vm.start":
            return try await handleVmsStart(params: request.params)
        case "vm.stop":
            return try await handleVmsStop(params: request.params)
        case "vm.exec":
            return try await handleVmsExec(params: request.params)
        case "vm.delete":
            return try await handleVmsDelete(params: request.params)
        case "vm.display":
            return try await handleVmsDisplay(params: request.params)
        case "vm.vnc.start":
            return try await handleVmsVNCStart(params: request.params)
        case "vm.vnc.stop":
            return try await handleVmsVNCStop(params: request.params)
        case "vm.bootScript":
            return try await handleVmsBootScript(params: request.params)
        case "vm.bootScript.status":
            return try await handleVmsBootScriptStatus(params: request.params)
        case "vm.screenshot":
            return try await handleVmsScreenshot(params: request.params)
        case "image.save":
            return try await handleImagesSave(params: request.params)
        case "image.list":
            return try await handleImagesList()
        case "image.delete":
            return try await handleImagesDelete(params: request.params)
        case "image.status":
            return try await handleImagesStatus()
        case "image.push":
            return try await handleImagesPush(params: request.params)
        case "image.pull":
            return try await handleImagesPull(params: request.params)
        case "gitlab.setup":
            return try await handleGitLabSetup(params: request.params)
        case "gitlab.status":
            return try await handleGitLabStatus()
        case "gitlab.start":
            return try await handleGitLabStart()
        case "gitlab.stop":
            return try await handleGitLabStop()
        default:
            throw APIHandlerError.unknownMethod(request.method)
        }
    }

    // MARK: - Handlers

    private func handleHealth() async throws -> AnyCodable {
        AnyCodable(["status": "ok", "version": "1.0.0"])
    }

    private func handleIpswList() async throws -> AnyCodable {
        let ipsws = vmManager.ipswManager.list()
        return AnyCodable(["ipsws": ipsws.map { ipsw in
            ["id": ipsw.id, "path": ipsw.path, "size": ipsw.size]
        }])
    }

    private func handleIpswPull() async throws -> AnyCodable {
        // Trigger download - happens async in background
        await vmManager.ipswManager.download()

        // Return current state
        return AnyCodable([
            "status": "started",
            "message": "IPSW download started"
        ])
    }

    private func handleIpswStatus() async throws -> AnyCodable {
        switch vmManager.ipswManager.state {
        case .none:
            return AnyCodable(["state": "none"])
        case .fetching:
            return AnyCodable(["state": "fetching"])
        case .downloading(let progress):
            return AnyCodable(["state": "downloading", "progress": progress] as [String: Any])
        case .downloaded:
            return AnyCodable(["state": "downloaded"])
        case .error(let message):
            return AnyCodable(["state": "error", "message": message] as [String: Any])
        }
    }

    private func handleVmsList() async throws -> AnyCodable {
        let vms = vmManager.listVMs()
        return AnyCodable(["vms": vms.map { vm in
            ["id": vm.id, "path": vm.path, "state": vm.state]
        }])
    }

    private func handleVmsCreate(params: [String: AnyCodable]?) async throws -> AnyCodable {
        let ipswId = params?["ipswId"]?.value as? String
        let sourceVmId = params?["sourceVmId"]?.value as? String
        let fromImage = params?["fromImage"]?.value as? String

        // Must have exactly one source
        let sources = [ipswId, sourceVmId, fromImage].compactMap { $0 }
        guard sources.count == 1 else {
            throw APIHandlerError.invalidParams("Must specify exactly one of 'ipswId', 'sourceVmId', or 'fromImage'")
        }

        // Create from image
        if let fromImage = fromImage {
            do {
                let vmId = try await vmManager.createVMFromImage(imageName: fromImage)
                await vmManager.startVM(vmId: vmId)
                try ensureStarted(vmId)
                return AnyCodable([
                    "status": "running",
                    "message": "VM created from image and started",
                    "vmId": vmId
                ])
            } catch let error as APIHandlerError {
                throw error
            } catch {
                throw APIHandlerError.invalidParams("Failed to create VM from image: \(error.localizedDescription)")
            }
        }

        // Create from IPSW
        if let ipswId = ipswId {
            // Verify IPSW exists
            let ipsws = vmManager.ipswManager.list()
            guard ipsws.contains(where: { $0.id == ipswId }) else {
                throw APIHandlerError.ipswNotFound(ipswId)
            }

            // Install runs in the background (~20 min); return the vmId now so
            // callers can poll vm.list for its state (creating → installing → running).
            let vmId = "vm-\(UUID().uuidString.prefix(8).lowercased())"
            Task { await vmManager.createAndStartVM(vmId: vmId) }

            return AnyCodable([
                "status": "started",
                "vmId": vmId,
                "message": "VM creation from IPSW started"
            ])
        }

        // Clone from existing VM
        if let sourceVmId = sourceVmId {
            do {
                let newVmId = try await vmManager.cloneVM(sourceVmId: sourceVmId)
                await vmManager.startVM(vmId: newVmId)
                try ensureStarted(newVmId)
                return AnyCodable([
                    "status": "running",
                    "message": "VM cloned and started",
                    "vmId": newVmId
                ])
            } catch let error as APIHandlerError {
                throw error
            } catch {
                throw APIHandlerError.cloneFailed(error.localizedDescription)
            }
        }

        throw APIHandlerError.invalidParams("Invalid parameters")
    }

    /// Verifies a just-started VM didn't land in an error state.
    private func ensureStarted(_ vmId: String) throws {
        guard let instance = vmManager.vmInstances[vmId] else {
            throw APIHandlerError.vmNotFound(vmId)
        }
        if case .error(let message) = instance.state {
            throw APIHandlerError.invalidParams("Failed to start VM: \(message)")
        }
    }

    private func handleVmsStart(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        await vmManager.startVM(vmId: vmId)

        // Check if VM actually started
        guard let instance = vmManager.vmInstances[vmId] else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        if case .error(let message) = instance.state {
            throw APIHandlerError.invalidParams("Failed to start VM: \(message)")
        }

        return AnyCodable([
            "status": "running",
            "vmId": vmId
        ])
    }

    /// The guest agent runs as root. When a `user` is requested, wrap the
    /// command in `su - <user> -c '…'` so it runs (with that user's login
    /// environment) as them instead. Done host-side so no agent change is
    /// needed. Any `args` are folded into the command string.
    private func applyUser(command: String, args: [String]?, user: String?) -> (command: String, args: [String]?) {
        guard let user, !user.isEmpty else { return (command, args) }
        func shQuote(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
        var full = command
        if let args, !args.isEmpty {
            full += " " + args.map(shQuote).joined(separator: " ")
        }
        return ("su - \(user) -c \(shQuote(full))", nil)
    }

    private func handleVmsExec(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }
        guard let rawCommand = params?["command"]?.value as? String else {
            throw APIHandlerError.missingParam("command")
        }
        let user = params?["user"]?.value as? String
        let (command, args) = applyUser(
            command: rawCommand,
            args: params?["args"]?.value as? [String],
            user: user
        )
        let waitForAgent = (params?["waitForAgent"]?.value as? Bool) ?? false

        do {
            let result = try await vmManager.executeCommand(command, args: args, vmId: vmId, waitForAgent: waitForAgent)
            return AnyCodable([
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exitCode": Int(result.exitCode)
            ])
        } catch {
            throw APIHandlerError.invalidParams("Exec failed: \(error.localizedDescription)")
        }
    }

    private func handleVmsStop(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        // Check if VM exists
        guard let instance = vmManager.vmInstances[vmId] else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        // Check if VM is actually running
        guard case .running = instance.state else {
            throw APIHandlerError.vmNotRunning(vmId)
        }

        // Stop the VM
        await vmManager.stopVM(vmId: vmId)

        return AnyCodable([
            "status": "stopped",
            "vmId": vmId
        ])
    }

    private func handleVmsDelete(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        // Delete the VM
        await vmManager.deleteVM(vmId: vmId)

        return AnyCodable([
            "status": "deleted",
            "vmId": vmId
        ])
    }

    private func handleVmsDisplay(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        guard let instance = vmManager.vmInstances[vmId] else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        guard case .running = instance.state else {
            throw APIHandlerError.vmNotRunning(vmId)
        }

        vmManager.requestDisplay(vmId: vmId)

        return AnyCodable([
            "status": "ok",
            "vmId": vmId
        ])
    }
    private func handleVmsVNCStart(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        guard vmManager.vmInstances[vmId] != nil else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        do {
            let url = try await vmManager.startVNC(vmId: vmId)
            return AnyCodable([
                "status": "ok",
                "vmId": vmId,
                "url": url
            ])
        } catch let error as PhantomError {
            if case .vmNotRunning = error {
                throw APIHandlerError.vmNotRunning(vmId)
            }
            throw APIHandlerError.invalidParams("Failed to start VNC: \(error.localizedDescription)")
        } catch {
            throw APIHandlerError.invalidParams("Failed to start VNC: \(error.localizedDescription)")
        }
    }

    private func handleVmsVNCStop(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        vmManager.stopVNC(vmId: vmId)

        return AnyCodable([
            "status": "stopped",
            "vmId": vmId
        ])
    }

    private func handleVmsBootScript(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }
        guard let commands = params?["commands"]?.value as? [String], !commands.isEmpty else {
            throw APIHandlerError.missingParam("commands")
        }

        guard vmManager.vmInstances[vmId] != nil else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        do {
            try await vmManager.runBootScript(vmId: vmId, commands: commands)
            return AnyCodable([
                "status": "started",
                "vmId": vmId,
                "total": commands.count
            ] as [String: Any])
        } catch let error as PhantomError {
            if case .vmNotRunning = error {
                throw APIHandlerError.vmNotRunning(vmId)
            }
            throw APIHandlerError.invalidParams(error.localizedDescription)
        } catch {
            throw APIHandlerError.invalidParams(error.localizedDescription)
        }
    }

    private func handleVmsBootScriptStatus(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        switch vmManager.bootScriptStates[vmId] ?? .idle {
        case .idle:
            return AnyCodable(["state": "idle"])
        case .running(let message):
            return AnyCodable(["state": "running", "message": message] as [String: Any])
        case .completed:
            return AnyCodable(["state": "completed"])
        case .error(let message):
            return AnyCodable(["state": "error", "message": message] as [String: Any])
        }
    }

    private func handleVmsScreenshot(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }
        let outputPath = params?["path"]?.value as? String

        guard vmManager.vmInstances[vmId] != nil else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        do {
            let path = try await vmManager.captureScreenshot(vmId: vmId, outputPath: outputPath)
            return AnyCodable(["status": "ok", "vmId": vmId, "path": path])
        } catch let error as PhantomError {
            if case .vmNotRunning = error {
                throw APIHandlerError.vmNotRunning(vmId)
            }
            throw APIHandlerError.invalidParams(error.localizedDescription)
        } catch {
            throw APIHandlerError.invalidParams(error.localizedDescription)
        }
    }

    // MARK: - Image Handlers

    private func handleImagesSave(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }
        guard let name = params?["name"]?.value as? String else {
            throw APIHandlerError.missingParam("name")
        }

        // Verify VM exists and is stopped
        guard let instance = vmManager.vmInstances[vmId] else {
            throw APIHandlerError.vmNotFound(vmId)
        }
        if case .running = instance.state {
            throw APIHandlerError.invalidParams("VM must be stopped before saving as image")
        }

        // Start save (async operation)
        Task {
            await vmManager.imageManager.save(name: name, bundlePath: instance.bundlePath)
        }

        return AnyCodable([
            "status": "started",
            "message": "Saving VM '\(vmId)' as image '\(name)'"
        ])
    }

    private func handleImagesList() async throws -> AnyCodable {
        let images = vmManager.imageManager.list()
        return AnyCodable(["images": images.map { img in
            [
                "name": img.name,
                "diskChunks": img.diskChunks,
                "totalSize": img.totalSize,
                "createdAt": img.createdAt
            ] as [String: Any]
        }])
    }

    private func handleImagesDelete(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let name = params?["name"]?.value as? String else {
            throw APIHandlerError.missingParam("name")
        }

        do {
            try vmManager.imageManager.delete(name: name)
            return AnyCodable(["status": "deleted", "name": name])
        } catch {
            throw APIHandlerError.invalidParams(error.localizedDescription)
        }
    }

    private func handleImagesPush(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let name = params?["name"]?.value as? String else {
            throw APIHandlerError.missingParam("name")
        }
        guard let reference = params?["reference"]?.value as? String else {
            throw APIHandlerError.missingParam("reference")
        }
        let username = params?["username"]?.value as? String
        let password = params?["password"]?.value as? String

        guard vmManager.imageManager.imageExists(name) else {
            throw APIHandlerError.invalidParams("Image not found: \(name)")
        }

        Task {
            await vmManager.imageManager.push(name: name, reference: reference, username: username, password: password)
        }

        return AnyCodable([
            "status": "started",
            "message": "Pushing image '\(name)' to \(reference)"
        ])
    }

    private func handleImagesPull(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let reference = params?["reference"]?.value as? String else {
            throw APIHandlerError.missingParam("reference")
        }
        let name = params?["name"]?.value as? String
        let username = params?["username"]?.value as? String
        let password = params?["password"]?.value as? String

        Task {
            await vmManager.imageManager.pull(reference: reference, name: name, username: username, password: password)
        }

        return AnyCodable([
            "status": "started",
            "message": "Pulling image from \(reference)"
        ])
    }

    private func handleGitLabSetup(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let url = params?["url"]?.value as? String else {
            throw APIHandlerError.missingParam("url")
        }
        guard let token = params?["token"]?.value as? String else {
            throw APIHandlerError.missingParam("token")
        }
        guard let image = params?["image"]?.value as? String else {
            throw APIHandlerError.missingParam("image")
        }
        guard let cliPath = params?["cliPath"]?.value as? String else {
            throw APIHandlerError.missingParam("cliPath")
        }
        let concurrent = params?["concurrent"]?.value as? Int

        guard vmManager.imageManager.imageExists(image) else {
            throw APIHandlerError.invalidParams("Image not found: \(image)")
        }

        do {
            try await vmManager.gitlabRunnerManager.setup(
                url: url,
                token: token,
                baseImage: image,
                cliPath: cliPath,
                concurrent: concurrent
            )
        } catch {
            throw APIHandlerError.invalidParams(error.localizedDescription)
        }

        return AnyCodable(vmManager.gitlabRunnerManager.statusInfo())
    }

    private func handleGitLabStatus() async throws -> AnyCodable {
        AnyCodable(vmManager.gitlabRunnerManager.statusInfo())
    }

    private func handleGitLabStart() async throws -> AnyCodable {
        do {
            try await vmManager.gitlabRunnerManager.start()
        } catch {
            throw APIHandlerError.invalidParams(error.localizedDescription)
        }
        return AnyCodable(vmManager.gitlabRunnerManager.statusInfo())
    }

    private func handleGitLabStop() async throws -> AnyCodable {
        vmManager.gitlabRunnerManager.stop()
        return AnyCodable(vmManager.gitlabRunnerManager.statusInfo())
    }

    private func handleImagesStatus() async throws -> AnyCodable {
        switch vmManager.imageManager.state {
        case .idle:
            return AnyCodable(["state": "idle"])
        case .saving(let progress, let message):
            return AnyCodable(["state": "saving", "progress": progress, "message": message] as [String: Any])
        case .pushing(let progress, let message):
            return AnyCodable(["state": "pushing", "progress": progress, "message": message] as [String: Any])
        case .pulling(let progress, let message):
            return AnyCodable(["state": "pulling", "progress": progress, "message": message] as [String: Any])
        case .completed(let message):
            return AnyCodable(["state": "completed", "message": message] as [String: Any])
        case .error(let message):
            return AnyCodable(["state": "error", "message": message] as [String: Any])
        }
    }
}

// MARK: - Streaming Models

struct StreamDoneChunk: Codable {
    let type: String  // "done"
    let exitCode: Int32
    let error: String?
}

// MARK: - Errors

enum APIHandlerError: LocalizedError {
    case unknownMethod(String)
    case missingParam(String)
    case invalidParams(String)
    case ipswNotFound(String)
    case vmNotFound(String)
    case vmNotRunning(String)
    case vmAlreadyExists(String)
    case cloneFailed(String)

    var code: String {
        switch self {
        case .unknownMethod: return "unknown_method"
        case .missingParam: return "missing_param"
        case .invalidParams: return "invalid_params"
        case .ipswNotFound: return "ipsw_not_found"
        case .vmNotFound: return "vm_not_found"
        case .vmNotRunning: return "vm_not_running"
        case .vmAlreadyExists: return "vm_already_exists"
        case .cloneFailed: return "clone_failed"
        }
    }

    var message: String {
        switch self {
        case .unknownMethod(let method):
            return "Unknown method: \(method)"
        case .missingParam(let param):
            return "Missing required parameter: \(param)"
        case .invalidParams(let message):
            return message
        case .ipswNotFound(let id):
            return "IPSW not found: \(id)"
        case .vmNotFound(let id):
            return "VM not found: \(id)"
        case .vmNotRunning(let id):
            return "VM is not running: \(id)"
        case .vmAlreadyExists(let message):
            return message
        case .cloneFailed(let message):
            return message
        }
    }

    var errorDescription: String? { message }
}
