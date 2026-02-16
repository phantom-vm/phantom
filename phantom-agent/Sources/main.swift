import Foundation

// MARK: - Protocol Models

struct ExecRequest: Codable {
    let command: String
    let args: [String]?
    let stream: Bool?
}

struct ExecResponse: Codable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct StreamChunk: Codable {
    let type: String  // "stdout", "stderr", "exit"
    let data: String?
    let exitCode: Int32?
}

// MARK: - Vsock Constants

// AF_VSOCK = 40 on macOS
let AF_VSOCK: Int32 = 40
let VMADDR_CID_ANY: UInt32 = 0xFFFFFFFF
let VSOCK_PORT: UInt32 = 9001

// sockaddr_vm layout for macOS
struct sockaddr_vm {
    var svm_len: UInt8
    var svm_family: UInt8
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32
}

// MARK: - Command Execution

func executeCommand(_ request: ExecRequest) -> ExecResponse {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")

    var fullCommand = request.command
    if let args = request.args, !args.isEmpty {
        let escaped = args.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        fullCommand += " " + escaped.joined(separator: " ")
    }
    process.arguments = ["-c", fullCommand]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ExecResponse(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    } catch {
        return ExecResponse(
            stdout: "",
            stderr: "Failed to launch process: \(error.localizedDescription)",
            exitCode: -1
        )
    }
}

// MARK: - Streaming Command Execution

func executeCommandStreaming(_ request: ExecRequest, clientFd: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")

    var fullCommand = request.command
    if let args = request.args, !args.isEmpty {
        let escaped = args.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        fullCommand += " " + escaped.joined(separator: " ")
    }
    process.arguments = ["-c", fullCommand]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let encoder = JSONEncoder()

    // Send a chunk over the connection
    func sendChunk(_ chunk: StreamChunk) {
        if let data = try? encoder.encode(chunk) {
            writeLine(data, to: clientFd)
        }
    }

    // Stream stdout
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
            sendChunk(StreamChunk(type: "stdout", data: str, exitCode: nil))
        }
    }

    // Stream stderr
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
            sendChunk(StreamChunk(type: "stderr", data: str, exitCode: nil))
        }
    }

    do {
        try process.run()
        process.waitUntilExit()

        // Clear handlers and flush remaining data
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Read any remaining buffered data
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty, let str = String(data: remainingStdout, encoding: .utf8) {
            sendChunk(StreamChunk(type: "stdout", data: str, exitCode: nil))
        }
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty, let str = String(data: remainingStderr, encoding: .utf8) {
            sendChunk(StreamChunk(type: "stderr", data: str, exitCode: nil))
        }

        sendChunk(StreamChunk(type: "exit", data: nil, exitCode: process.terminationStatus))
    } catch {
        sendChunk(StreamChunk(type: "stderr", data: "Failed to launch process: \(error.localizedDescription)", exitCode: nil))
        sendChunk(StreamChunk(type: "exit", data: nil, exitCode: -1))
    }
}

// MARK: - Socket Helpers

func readLine(from fd: Int32) -> Data? {
    var buffer = Data()
    var byte: UInt8 = 0
    while true {
        let n = read(fd, &byte, 1)
        if n <= 0 { return nil }
        if byte == 0x0A { // newline
            return buffer
        }
        buffer.append(byte)
    }
}

func writeLine(_ data: Data, to fd: Int32) {
    var payload = data
    payload.append(0x0A) // newline
    payload.withUnsafeBytes { ptr in
        _ = write(fd, ptr.baseAddress!, ptr.count)
    }
}

// MARK: - Main

print("phantom-agent: starting on vsock port \(VSOCK_PORT)...")

let sockFd = socket(AF_VSOCK, SOCK_STREAM, 0)
guard sockFd >= 0 else {
    perror("socket")
    exit(1)
}

var addr = sockaddr_vm(
    svm_len: UInt8(MemoryLayout<sockaddr_vm>.size),
    svm_family: UInt8(AF_VSOCK),
    svm_reserved1: 0,
    svm_port: VSOCK_PORT,
    svm_cid: VMADDR_CID_ANY
)

let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(sockFd, sockPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
}
guard bindResult == 0 else {
    perror("bind")
    close(sockFd)
    exit(1)
}

guard listen(sockFd, 5) == 0 else {
    perror("listen")
    close(sockFd)
    exit(1)
}

print("phantom-agent: listening for connections...")

let decoder = JSONDecoder()
let encoder = JSONEncoder()

// Accept loop
while true {
    var clientAddr = sockaddr_vm(
        svm_len: 0, svm_family: 0, svm_reserved1: 0, svm_port: 0, svm_cid: 0
    )
    var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

    let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            accept(sockFd, sockPtr, &addrLen)
        }
    }

    guard clientFd >= 0 else {
        perror("accept")
        continue
    }

    print("phantom-agent: client connected")

    // Handle commands from this connection (one per line)
    while let lineData = readLine(from: clientFd) {
        do {
            let request = try decoder.decode(ExecRequest.self, from: lineData)
            print("phantom-agent: executing '\(request.command)' (stream: \(request.stream ?? false))")

            if request.stream == true {
                executeCommandStreaming(request, clientFd: clientFd)
            } else {
                let response = executeCommand(request)
                let responseData = try encoder.encode(response)
                writeLine(responseData, to: clientFd)
            }
        } catch {
            let errorResponse = ExecResponse(
                stdout: "",
                stderr: "Failed to parse request: \(error.localizedDescription)",
                exitCode: -1
            )
            if let data = try? encoder.encode(errorResponse) {
                writeLine(data, to: clientFd)
            }
        }
    }

    print("phantom-agent: client disconnected")
    close(clientFd)
}
