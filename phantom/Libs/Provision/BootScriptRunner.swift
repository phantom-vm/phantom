import Foundation
import Vision

/// Executes parsed boot commands against a VM's VNC server: types keystrokes,
/// waits, and resolves `<click 'text'>` steps by OCR-ing the framebuffer with
/// Vision and clicking the matched text.
///
/// Blocking I/O — run from a background task.
nonisolated final class BootScriptRunner {

    enum RunnerError: LocalizedError {
        case textNotFound(String)

        var errorDescription: String? {
            switch self {
            case .textNotFound(let text): "Text not found on screen: '\(text)'"
            }
        }
    }

    /// Delay between individual keystrokes. Setup Assistant drops keys typed
    /// at full speed, so pace them like Packer does.
    private let keystrokeInterval: UInt32 = 100_000 // 100ms

    private var client: RFBClient
    private let vncPort: UInt16
    private let vncPassword: String
    private let onProgress: @Sendable (String) -> Void

    init(vncPort: UInt16, vncPassword: String, onProgress: @escaping @Sendable (String) -> Void) throws {
        self.vncPort = vncPort
        self.vncPassword = vncPassword
        self.client = try RFBClient(port: vncPort, password: vncPassword)
        self.onProgress = onProgress
    }

    /// Runs a VNC operation, reconnecting once if the connection dropped. The
    /// display changes resolution across the boot → Setup Assistant transition,
    /// which makes `_VZVNCServer` drop the client; a fresh connection re-syncs
    /// to the new geometry.
    @discardableResult
    private func withReconnect<T>(_ op: (RFBClient) throws -> T) throws -> T {
        do {
            return try op(client)
        } catch RFBClient.RFBError.connectionClosed {
            onProgress("VNC connection dropped, reconnecting...")
            client = try RFBClient(port: vncPort, password: vncPassword)
            return try op(client)
        }
    }

    /// Runs boot commands sequentially. Each command is reported to
    /// `onProgress` before execution.
    func run(commands: [String]) async throws {
        let parsed = try BootCommand.parse(commands: commands)

        for (index, steps) in parsed.enumerated() {
            onProgress("[\(index + 1)/\(commands.count)] \(commands[index])")
            for step in steps {
                try await execute(step)
            }
        }
    }

    private func execute(_ step: BootCommand.Step) async throws {
        switch step {
        case .wait(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        case .keyDown(let keysym):
            try withReconnect { try $0.sendKey(keysym, down: true) }
            usleep(keystrokeInterval)

        case .keyUp(let keysym):
            try withReconnect { try $0.sendKey(keysym, down: false) }
            usleep(keystrokeInterval)

        case .keyPress(let keysym):
            try withReconnect { try $0.pressKey(keysym) }
            usleep(keystrokeInterval)

        case .typeText(let text):
            for character in text {
                guard let keysym = BootCommand.keysym(for: character) else { continue }
                // _VZVNCServer maps a keysym to a physical key but does not
                // apply its shift level, so uppercase letters and shifted
                // symbols (|, &, _, :, ...) need Shift held explicitly.
                try withReconnect { client in
                    if BootCommand.requiresShift(character) {
                        try client.sendKey(BootCommand.leftShift, down: true)
                        try client.pressKey(keysym)
                        try client.sendKey(BootCommand.leftShift, down: false)
                    } else {
                        try client.pressKey(keysym)
                    }
                }
                usleep(keystrokeInterval)
            }

        case .click(let text):
            try await clickText(text)

        case .waitFor(let text):
            try await waitForText(text)
        }
    }

    // MARK: - OCR click

    /// OCRs the framebuffer looking for `text`, retrying while the screen
    /// settles, then clicks the center of the matched text.
    private func clickText(_ text: String, attempts: Int = 12, retryDelay: TimeInterval = 5) async throws {
        for attempt in 1...attempts {
            let image = try withReconnect { try $0.captureFramebuffer() }
            if let center = try Self.findText(text, in: image) {
                onProgress("Found '\(text)' at (\(center.x), \(center.y)), clicking")
                try withReconnect { try $0.clickAt(x: center.x, y: center.y) }
                return
            }
            if attempt < attempts {
                onProgress("'\(text)' not on screen yet (attempt \(attempt)/\(attempts))")
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        throw RunnerError.textNotFound(text)
    }

    /// Blocks until `text` appears on screen (does not click). Used to gate the
    /// script on a slow screen transition — e.g. the cold boot to Setup
    /// Assistant, which can take minutes — instead of a fixed `<wait>`.
    private func waitForText(_ text: String, timeout: TimeInterval = 600, retryDelay: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            // Capture failures (the connection flaps as the display resolution
            // settles during boot) are non-fatal here — just try again.
            do {
                let image = try withReconnect { client -> CGImage in
                    // The display may be black/asleep early in boot; nudge it awake.
                    try? client.sendKey(BootCommand.leftShift, down: true)
                    try? client.sendKey(BootCommand.leftShift, down: false)
                    return try client.captureFramebuffer()
                }
                if try Self.findText(text, in: image) != nil {
                    onProgress("'\(text)' appeared (after \(attempt) checks)")
                    return
                }
                onProgress("waiting for '\(text)' (\(attempt))")
            } catch {
                onProgress("waiting for '\(text)' (\(attempt), reconnecting)")
            }
            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
        throw RunnerError.textNotFound(text)
    }

    /// Returns the framebuffer-pixel center of the recognized text, or nil.
    private static func findText(_ text: String, in image: CGImage) throws -> (x: Int, y: Int)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        let target = text.lowercased()

        // Rank matches so that an exact label wins over a substring: this keeps
        // `<click 'Agree'>` off the "Disagree" button and `<click 'Skip'>` off
        // "Don't Skip". 0 = exact, 1 = word match, 2 = substring.
        var best: (rank: Int, x: Int, y: Int)?

        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let recognized = candidate.string.lowercased()
            guard recognized.contains(target) else { continue }

            let trimmed = recognized.trimmingCharacters(in: .whitespacesAndPunctuation)
            let words = recognized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let rank: Int
            if trimmed == target {
                rank = 0
            } else if words.contains(target) {
                rank = 1
            } else {
                rank = 2
            }

            // Bounding box of just the matched substring when available,
            // otherwise the whole observation
            var box = observation.boundingBox
            if let range = candidate.string.lowercased().range(of: target),
               let substringBox = try? candidate.boundingBox(for: range) {
                box = substringBox.boundingBox
            }

            // Vision coordinates are normalized with origin at bottom-left
            let x = Int(box.midX * CGFloat(image.width))
            let y = Int((1 - box.midY) * CGFloat(image.height))

            if best == nil || rank < best!.rank {
                best = (rank, x, y)
                if rank == 0 { break }
            }
        }

        guard let best else { return nil }
        return (best.x, best.y)
    }
}

private extension CharacterSet {
    static var whitespacesAndPunctuation: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.punctuationCharacters)
        return set
    }
}
