import Foundation

@MainActor
struct APIHandlers {
    let vmManager: VMManager

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
        case "vms.list":
            return try await handleVmsList()
        case "vms.create":
            return try await handleVmsCreate(params: request.params)
        case "vms.start":
            return try await handleVmsStart(params: request.params)
        case "vms.stop":
            return try await handleVmsStop(params: request.params)
        case "vms.exec":
            return try await handleVmsExec(params: request.params)
        case "vms.delete":
            return try await handleVmsDelete(params: request.params)
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

        // Must have exactly one source
        guard (ipswId != nil) != (sourceVmId != nil) else {
            throw APIHandlerError.invalidParams("Must specify either 'ipswId' or 'sourceVmId', but not both")
        }

        // Create from IPSW
        if let ipswId = ipswId {
            // Verify IPSW exists
            let ipsws = vmManager.ipswManager.list()
            guard ipsws.contains(where: { $0.id == ipswId }) else {
                throw APIHandlerError.ipswNotFound(ipswId)
            }

            // Start VM creation (async operation)
            await vmManager.createAndStartVM()

            return AnyCodable([
                "status": "started",
                "message": "VM creation from IPSW started"
            ])
        }

        // Clone from existing VM
        if let sourceVmId = sourceVmId {
            // Clone the VM (async operation)
            do {
                let newVmId = try await vmManager.cloneVM(sourceVmId: sourceVmId)
                return AnyCodable([
                    "status": "success",
                    "message": "VM cloned successfully",
                    "vmId": newVmId
                ])
            } catch {
                throw APIHandlerError.cloneFailed(error.localizedDescription)
            }
        }

        throw APIHandlerError.invalidParams("Invalid parameters")
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

    private func handleVmsExec(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }
        guard let command = params?["command"]?.value as? String else {
            throw APIHandlerError.missingParam("command")
        }
        let args = (params?["args"]?.value as? [String])
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
