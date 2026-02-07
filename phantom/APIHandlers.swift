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
            return try await handleImagesList()
        case "ipsw.pull":
            return try await handleImagesPull()
        case "vms.list":
            return try await handleVmsList()
        case "vms.create":
            return try await handleVmsCreate(params: request.params)
        case "vms.stop":
            return try await handleVmsStop(params: request.params)
        default:
            throw APIHandlerError.unknownMethod(request.method)
        }
    }

    // MARK: - Handlers

    private func handleHealth() async throws -> AnyCodable {
        AnyCodable(["status": "ok", "version": "1.0.0"])
    }

    private func handleImagesList() async throws -> AnyCodable {
        let images = vmManager.listImages()
        return AnyCodable(["images": images.map { image in
            ["id": image.id, "path": image.path, "size": image.size]
        }])
    }

    private func handleImagesPull() async throws -> AnyCodable {
        // Trigger download - happens async in background
        await vmManager.downloadImage()

        // Return current state
        return AnyCodable([
            "status": "started",
            "message": "Image download started"
        ])
    }

    private func handleVmsList() async throws -> AnyCodable {
        let vms = vmManager.listVMs()
        return AnyCodable(["vms": vms.map { vm in
            ["id": vm.id, "path": vm.path, "state": vm.state]
        }])
    }

    private func handleVmsCreate(params: [String: AnyCodable]?) async throws -> AnyCodable {
        let imageId = params?["imageId"]?.value as? String
        let sourceVmId = params?["sourceVmId"]?.value as? String

        // Must have exactly one source
        guard (imageId != nil) != (sourceVmId != nil) else {
            throw APIHandlerError.invalidParams("Must specify either 'imageId' or 'sourceVmId', but not both")
        }

        // Check if already creating/installing/running
        switch vmManager.vmState {
        case .creating, .installing, .running:
            throw APIHandlerError.vmAlreadyExists("A VM is already running or being created")
        default:
            break
        }

        // Create from IPSW image
        if let imageId = imageId {
            // Verify image exists
            let images = vmManager.listImages()
            guard images.contains(where: { $0.id == imageId }) else {
                throw APIHandlerError.imageNotFound(imageId)
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

    private func handleVmsStop(params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let vmId = params?["vmId"]?.value as? String else {
            throw APIHandlerError.missingParam("vmId")
        }

        // Check if specified VM is the current running VM
        guard let currentPath = vmManager.currentBundlePath,
              currentPath.lastPathComponent == vmId else {
            throw APIHandlerError.vmNotFound(vmId)
        }

        // Check if VM is actually running
        guard case .running = vmManager.vmState else {
            throw APIHandlerError.vmNotRunning(vmId)
        }

        // Stop the VM
        await vmManager.stopVM()

        return AnyCodable([
            "status": "stopped",
            "vmId": vmId
        ])
    }
}

// MARK: - Errors

enum APIHandlerError: LocalizedError {
    case unknownMethod(String)
    case missingParam(String)
    case invalidParams(String)
    case imageNotFound(String)
    case vmNotFound(String)
    case vmNotRunning(String)
    case vmAlreadyExists(String)
    case cloneFailed(String)

    var code: String {
        switch self {
        case .unknownMethod: return "unknown_method"
        case .missingParam: return "missing_param"
        case .invalidParams: return "invalid_params"
        case .imageNotFound: return "image_not_found"
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
        case .imageNotFound(let id):
            return "Image not found: \(id)"
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
