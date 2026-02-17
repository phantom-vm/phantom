import Foundation
import Network

@MainActor
@Observable
class TCPServer {
    // MARK: - State

    private(set) var isRunning: Bool = false
    private(set) var port: UInt16

    // MARK: - Private

    private var listener: NWListener?
    private weak var vmManager: VMManager?
    private var activeConnections: Set<ConnectionWrapper> = []

    // MARK: - Init

    init(vmManager: VMManager, port: UInt16 = 9090) {
        self.vmManager = vmManager
        self.port = port
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPServerError.invalidPort
        }

        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    print("TCPServer: listening on port \(self.port)")
                    self.isRunning = true
                case .failed(let error):
                    print("TCPServer: listener failed: \(error)")
                    self.isRunning = false
                case .cancelled:
                    print("TCPServer: listener cancelled")
                    self.isRunning = false
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleConnection(connection)
            }
        }

        listener.start(queue: .global())
    }

    func stop() {
        guard isRunning else { return }

        // Cancel all active connections
        for wrapper in activeConnections {
            wrapper.connection.cancel()
        }
        activeConnections.removeAll()

        // Stop listener
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let wrapper = ConnectionWrapper(connection: connection)
        activeConnections.insert(wrapper)

        connection.stateUpdateHandler = { state in
            Task { @MainActor [weak self, weak wrapper] in
                guard let self, let wrapper else { return }
                switch state {
                case .ready:
                    self.receiveRequest(on: connection)
                case .failed(let error):
                    print("TCPServer: connection failed: \(error)")
                    self.activeConnections.remove(wrapper)
                case .cancelled:
                    self.activeConnections.remove(wrapper)
                default:
                    break
                }
            }
        }

        connection.start(queue: .global())
    }

    private func receiveRequest(on connection: NWConnection) {
        // Read up to 64KB
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error {
                print("TCPServer: receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data else {
                connection.cancel()
                return
            }

            // Find newline delimiter
            guard let newlineIndex = data.firstIndex(of: 0x0A) else {
                // No newline yet - for simplicity, we'll just reject invalid requests
                // Production code should buffer and keep reading
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let errorData = self.errorResponse(code: "invalid_request", message: "Request must end with newline")
                    self.sendResponse(errorData, to: connection)
                }
                return
            }

            let requestData = data.prefix(upTo: newlineIndex)

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.processRequest(requestData, connection: connection)
            }
        }
    }

    private func processRequest(_ data: Data, connection: NWConnection) async {
        guard let vmManager else {
            sendResponse(errorResponse(code: "server_error", message: "VM manager not available"), to: connection)
            return
        }

        guard let request = try? JSONDecoder().decode(APIRequest.self, from: data) else {
            sendResponse(errorResponse(code: "invalid_request", message: "Failed to decode JSON request"), to: connection)
            return
        }

        // Streaming methods keep the connection open
        if request.method == "vms.execStream" {
            let handlers = APIHandlers(vmManager: vmManager)
            await handlers.handleStream(request) { chunk in
                self.sendChunk(chunk, to: connection)
            }
            connection.cancel()
            return
        }

        let handlers = APIHandlers(vmManager: vmManager)
        let responseData = await handlers.handle(request)
        sendResponse(responseData, to: connection)
    }

    private func sendResponse(_ data: Data, to connection: NWConnection) {
        var response = data
        response.append(0x0A) // newline delimiter

        connection.send(content: response, completion: .contentProcessed { error in
            if let error {
                print("TCPServer: send error: \(error)")
            }
            // Close connection after response (one request per connection)
            connection.cancel()
        })
    }

    private nonisolated func sendChunk(_ data: Data, to connection: NWConnection) {
        var chunk = data
        chunk.append(0x0A) // newline delimiter

        let semaphore = DispatchSemaphore(value: 0)
        connection.send(content: chunk, completion: .contentProcessed { error in
            if let error {
                print("TCPServer: chunk send error: \(error)")
            }
            semaphore.signal()
        })
        semaphore.wait()
    }

    private func errorResponse(code: String, message: String) -> Data {
        let error = APIError(code: code, message: message)
        let response = APIResponse(result: nil, error: error)
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

// MARK: - Connection Wrapper

private class ConnectionWrapper: Hashable {
    let connection: NWConnection
    private let id = UUID()

    init(connection: NWConnection) {
        self.connection = connection
    }

    static func == (lhs: ConnectionWrapper, rhs: ConnectionWrapper) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Errors

enum TCPServerError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid port number"
        }
    }
}
