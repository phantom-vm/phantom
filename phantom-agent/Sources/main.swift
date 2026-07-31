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

// MARK: - Stopping a Command

/// How long a command gets to wind down after the host hangs up, before it is
/// killed outright.
let hangUpGracePeriod: TimeInterval = 5

/// Every process `pid` started, deepest first.
///
/// A command arrives as `/bin/sh -c …`, so the shell is only the top of the
/// tree — a CI job script is another shell below it, and its compiler below
/// that. Signalling the shell alone leaves the real work running, reparented to
/// launchd and still holding the CPU.
func descendants(of pid: pid_t) -> [pid_t] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-Ao", "pid=,ppid="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()

    var childrenByParent: [pid_t: [pid_t]] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let child = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
        childrenByParent[parent, default: []].append(child)
    }

    // Breadth-first from `pid`, then reversed, so a child is signalled before
    // the parent whose death would otherwise reparent it.
    var found: [pid_t] = []
    var queue = childrenByParent[pid] ?? []
    while !queue.isEmpty {
        let next = queue.removeFirst()
        found.append(next)
        queue.append(contentsOf: childrenByParent[next] ?? [])
    }
    return found.reversed()
}

func signalTree(of pid: pid_t, _ signalNumber: Int32) {
    for descendant in descendants(of: pid) { kill(descendant, signalNumber) }
    kill(pid, signalNumber)
}

/// Watch a client connection for the host hanging up while its command runs.
///
/// The host closes the connection when whoever asked for the command has gone —
/// a cancelled CI job, a `phantom vm exec` interrupted at the terminal. Nothing
/// used to be watching: the command ran to completion with nobody to report to,
/// and since this agent handles one command per connection, every other exec on
/// the VM waited behind it. A killed `phantom vm exec … sleep 120` measurably
/// cost the next exec on that VM 117 seconds.
final class HangUpWatcher {
    private let clientFd: Int32
    private let onHangUp: () -> Void
    private let lock = NSLock()
    private var stopped = false

    init(clientFd: Int32, onHangUp: @escaping () -> Void) {
        self.clientFd = clientFd
        self.onHangUp = onHangUp
    }

    func start() {
        Thread.detachNewThread { [self] in
            while !isStopped {
                var toWatch = pollfd(fd: clientFd, events: Int16(POLLIN), revents: 0)
                // Polled with a timeout rather than waited on outright, so the
                // thread also notices `stop()` once the command has finished.
                let ready = poll(&toWatch, 1, 500)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }

                // Readable, or hung up. The host says nothing while a command
                // runs, so a peek that reads end-of-file is the connection
                // closing; anything else is left in the buffer for the reader
                // that owns this socket between commands.
                var byte: UInt8 = 0
                let peeked = recv(clientFd, &byte, 1, MSG_PEEK)
                if peeked == 0 || (peeked < 0 && errno != EINTR && errno != EAGAIN) {
                    if !isStopped { onHangUp() }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Run `process` to completion, stopping it if the client hangs up first.
func waitForExit(_ process: Process, clientFd: Int32) {
    let watcher = HangUpWatcher(clientFd: clientFd) { [weak process] in
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        print("phantom-agent: client hung up — stopping \(pid)")
        signalTree(of: pid, SIGTERM)
        // For anything that ignores SIGTERM. There is nothing left to read the
        // output, so there is no reason to keep waiting on it.
        DispatchQueue.global().asyncAfter(deadline: .now() + hangUpGracePeriod) {
            if process.isRunning { signalTree(of: pid, SIGKILL) }
        }
    }
    watcher.start()
    process.waitUntilExit()
    watcher.stop()
}

// MARK: - Command Execution

func executeCommand(_ request: ExecRequest, clientFd: Int32) -> ExecResponse {
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
        waitForExit(process, clientFd: clientFd)

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
    let writeQueue = DispatchQueue(label: "phantom-agent.write")

    // Send a chunk over the connection (serialized to avoid interleaved writes)
    func sendChunk(_ chunk: StreamChunk) {
        if let data = try? encoder.encode(chunk) {
            writeQueue.sync {
                writeLine(data, to: clientFd)
            }
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
        waitForExit(process, clientFd: clientFd)

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

// MARK: - Serving Clients

/// Serve one client until it goes away: commands arrive one per line, and each
/// runs to completion before the next is read.
///
/// Runs on its own thread. A single accept loop meant one long command held the
/// agent, and every other exec on the VM waited in the listen backlog until it
/// finished — however long after anyone still cared about the answer.
func serveClient(_ clientFd: Int32) {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    while let lineData = readLine(from: clientFd) {
        do {
            let request = try decoder.decode(ExecRequest.self, from: lineData)
            print("phantom-agent: executing '\(request.command)' (stream: \(request.stream ?? false))")

            if request.stream == true {
                executeCommandStreaming(request, clientFd: clientFd)
            } else {
                let response = executeCommand(request, clientFd: clientFd)
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

// MARK: - Main

// So an installer (or a human) can ask a downloaded binary what it is
// without starting a vsock listener.
if CommandLine.arguments.contains("--version") {
    print(phantomAgentVersion)
    exit(0)
}

print("phantom-agent \(phantomAgentVersion): starting on vsock port \(VSOCK_PORT)...")

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
    Thread.detachNewThread { serveClient(clientFd) }
}
