import AppKit
import Foundation

/// Downloads, registers, and supervises a GitLab Runner process so users
/// don't have to install or configure gitlab-runner themselves.
///
/// Layout under Application Support/phantom/gitlab-runner/:
///   v18.11.2/gitlab-runner   — versioned binary downloaded from GitLab S3
///   config.toml              — runner config owned by phantom (never touches ~/.gitlab-runner)
///   template.toml            — register template pointing the custom executor at phantom-cli
@MainActor
@Observable
class GitLabRunnerManager {

    static let runnerVersion = "v18.11.2"

    // MARK: - State

    enum State: Equatable {
        case notConfigured
        case downloading
        case registering
        case running
        case stopped
        case error(String)
    }

    private(set) var state: State = .notConfigured

    /// The runner's own log: the process's stdout/stderr plus this manager's
    /// lifecycle messages.
    ///
    /// Separate from `VMManager.logs` because the runner is a separate process. The
    /// daemon logs sparse discrete events; the runner emits a continuous stream, and
    /// sharing one array buried the former under the latter. It also starts, stops
    /// and crashes on its own schedule, so its log has its own beginning and end —
    /// and the manager that owns the process should own its output rather than
    /// borrowing the daemon's sink and tagging lines so a view can sniff them back
    /// out.
    private(set) var output = LogBuffer()

    // MARK: - Private

    private let runnerDir: URL

    /// Only the runner's state transitions go to the daemon log — someone reading it
    /// needs to learn the runner died without wading through the runner's output.
    private let daemonLog: (String) -> Void

    private var runnerProcess: Process?

    /// Reassembles whole lines from unaligned pipe reads and strips ANSI codes.
    private var lineAssembler = LineAssembler()

    /// Set when stop() is requested so the termination handler can tell an
    /// intentional stop from a crash
    private var stopRequested = false

    /// The manager's lifecycle messages go to the runner's own log, next to the
    /// output they explain.
    private func log(_ message: String) {
        output.append(message)
    }

    private func ingest(_ text: String) {
        for line in lineAssembler.take(text) {
            output.append(line)
        }
    }

    private var versionDir: URL { runnerDir.appendingPathComponent(Self.runnerVersion, isDirectory: true) }
    private var binaryPath: URL { versionDir.appendingPathComponent("gitlab-runner") }
    /// Not private: the Info tab shows it, and `gitlab.status` already publishes
    /// it over the TCP API, so it is not a secret.
    var configPath: URL { runnerDir.appendingPathComponent("config.toml") }
    private var templatePath: URL { runnerDir.appendingPathComponent("template.toml") }

    private var downloadURL: URL {
        URL(string: "https://gitlab-runner-downloads.s3.amazonaws.com/\(Self.runnerVersion)/binaries/gitlab-runner-darwin-arm64")!
    }

    var isConfigured: Bool { FileManager.default.fileExists(atPath: configPath.path) }
    var isBinaryDownloaded: Bool { FileManager.default.fileExists(atPath: binaryPath.path) }
    var isRunning: Bool { runnerProcess?.isRunning ?? false }

    init(runnerDir: URL, daemonLog: @escaping (String) -> Void) {
        self.runnerDir = runnerDir
        self.daemonLog = daemonLog
        try? FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        if isConfigured { state = .stopped }

        // The runner is a child process and would be orphaned if the app
        // quits without stopping it — leading to duplicate runners after
        // relaunch. Stop it on normal termination.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRunner() }
        }
    }

    // MARK: - Public API

    /// Called on app launch: resume the runner if a previous setup left a config behind
    func autostart() async {
        guard isConfigured else { return }
        do {
            if !isBinaryDownloaded {
                try await downloadBinary()
            }
            try startRunner()
            log("GitLab runner resumed from existing config")
        } catch {
            state = .error(error.localizedDescription)
            log("GitLab runner autostart failed: \(error.localizedDescription)")
            daemonLog("GitLab runner autostart failed: \(error.localizedDescription)")
        }
    }

    /// One-shot setup: download binary, register against GitLab, start the runner.
    /// Re-running replaces the previous registration. Jobs pick their VM image
    /// via the `image:` keyword — the runner has no image configuration.
    func setup(url: String, token: String, cliPath: String, concurrent: Int?) async throws {
        if !isBinaryDownloaded {
            try await downloadBinary()
        }

        stopRunner()

        // A previous config would make `register` append a second [[runners]]
        // entry; setup semantics are "replace", so start clean
        if isConfigured {
            log("Existing runner config found — replacing")
            try? FileManager.default.removeItem(at: configPath)
        }

        try writeTemplate(cliPath: cliPath)

        state = .registering
        log("Registering runner with \(url)...")
        let (status, output) = try await runProcess(binaryPath, [
            "register",
            "--non-interactive",
            "--config", configPath.path,
            "--template-config", templatePath.path,
            "--url", url,
            "--token", token,
            "--executor", "custom",
        ])
        guard status == 0, isConfigured else {
            state = .error("Registration failed")
            throw GitLabRunnerError.registrationFailed(output)
        }
        log("Runner registered")

        if let concurrent, concurrent > 1 {
            try patchConcurrent(concurrent)
        }

        try startRunner()
    }

    func start() async throws {
        guard isConfigured else { throw GitLabRunnerError.notConfigured }
        if isRunning { return }
        if !isBinaryDownloaded {
            try await downloadBinary()
        }
        try startRunner()
    }

    func stop() {
        stopRunner()
    }

    func statusInfo() -> [String: Any] {
        let stateString: String
        switch state {
        case .notConfigured: stateString = "not_configured"
        case .downloading: stateString = "downloading"
        case .registering: stateString = "registering"
        case .running: stateString = "running"
        case .stopped: stateString = "stopped"
        case .error(let message): stateString = "error: \(message)"
        }
        return [
            "state": stateString,
            "configured": isConfigured,
            "running": isRunning,
            "version": Self.runnerVersion,
            "binaryDownloaded": isBinaryDownloaded,
            "configPath": configPath.path,
        ]
    }

    // MARK: - Download

    private func downloadBinary() async throws {
        state = .downloading
        log("Downloading gitlab-runner \(Self.runnerVersion)...")
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            state = .error("Download failed (HTTP \(code))")
            throw GitLabRunnerError.downloadFailed("HTTP \(code)")
        }

        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: binaryPath.path) {
            try FileManager.default.removeItem(at: binaryPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: binaryPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
        // Gatekeeper only blocks quarantined executables — make sure the
        // attribute is absent regardless of how the file was written
        removexattr(binaryPath.path, "com.apple.quarantine", 0)
        log("gitlab-runner \(Self.runnerVersion) downloaded to \(binaryPath.path)")
    }

    // MARK: - Config

    private func writeTemplate(cliPath: String) throws {
        let template = """
        [[runners]]
          builds_dir = "/tmp/builds"
          cache_dir = "/tmp/cache"
          [runners.custom]
            # How long the runner waits for a stage it has signalled before it
            # escalates, and then gives up. A stage that is behaving exits on
            # SIGTERM in milliseconds, so these only bound a stage that hangs —
            # and the defaults are ten minutes each, which nothing here is
            # worth.
            graceful_kill_timeout = 60
            force_kill_timeout = 30
            prepare_exec = "\(cliPath)"
            prepare_args = ["gitlab-runner", "prepare"]
            run_exec = "\(cliPath)"
            run_args = ["gitlab-runner", "run"]
            cleanup_exec = "\(cliPath)"
            cleanup_args = ["gitlab-runner", "cleanup"]
        """
        try template.write(to: templatePath, atomically: true, encoding: .utf8)
    }

    /// `register --template-config` only merges [[runners]] settings, so the
    /// global `concurrent` key has to be patched after registration
    private func patchConcurrent(_ concurrent: Int) throws {
        var config = try String(contentsOf: configPath, encoding: .utf8)
        if let range = config.range(of: #"(?m)^concurrent = \d+$"#, options: .regularExpression) {
            config.replaceSubrange(range, with: "concurrent = \(concurrent)")
        } else {
            config = "concurrent = \(concurrent)\n" + config
        }
        try config.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Process Supervision

    private func startRunner() throws {
        killStaleRunners()

        let process = Process()
        process.executableURL = binaryPath
        process.arguments = ["run", "--config", configPath.path, "--working-directory", runnerDir.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.ingest(text)
            }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                if let tail = self.lineAssembler.flush() { self.output.append(tail) }
                self.runnerProcess = nil
                if self.stopRequested {
                    self.state = .stopped
                    self.log("GitLab runner stopped")
                    self.daemonLog("GitLab runner stopped")
                } else {
                    self.state = .error("Runner exited unexpectedly (status \(proc.terminationStatus))")
                    self.log("GitLab runner exited unexpectedly (status \(proc.terminationStatus))")
                    self.daemonLog("GitLab runner exited unexpectedly (status \(proc.terminationStatus))")
                }
            }
        }

        stopRequested = false
        try process.run()
        runnerProcess = process
        state = .running
        log("GitLab runner started (pid \(process.processIdentifier))")
        daemonLog("GitLab runner started (pid \(process.processIdentifier))")
    }

    /// A daemon instance that died without cleanup leaves an orphaned runner
    /// behind; two runners on the same config would both poll for jobs
    private func killStaleRunners() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "gitlab-runner run --config \(configPath.path)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func stopRunner() {
        guard let process = runnerProcess, process.isRunning else { return }
        stopRequested = true
        process.terminate()
        process.waitUntilExit()
        runnerProcess = nil
        state = .stopped
    }

    /// Run a short-lived subprocess and capture its combined output
    private func runProcess(_ executable: URL, _ args: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Errors

enum GitLabRunnerError: LocalizedError {
    case downloadFailed(String)
    case registrationFailed(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "gitlab-runner download failed: \(message)"
        case .registrationFailed(let output):
            return "Runner registration failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .notConfigured:
            return "GitLab runner is not set up — run 'phantom gitlab-runner setup' first"
        }
    }
}
