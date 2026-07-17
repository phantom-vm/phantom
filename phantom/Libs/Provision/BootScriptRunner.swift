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

    private let client: RFBClient
    private let onProgress: @Sendable (String) -> Void

    init(vncPort: UInt16, vncPassword: String, onProgress: @escaping @Sendable (String) -> Void) throws {
        self.client = try RFBClient(port: vncPort, password: vncPassword)
        self.onProgress = onProgress
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
            try client.sendKey(keysym, down: true)
            usleep(keystrokeInterval)

        case .keyUp(let keysym):
            try client.sendKey(keysym, down: false)
            usleep(keystrokeInterval)

        case .keyPress(let keysym):
            try client.pressKey(keysym)
            usleep(keystrokeInterval)

        case .typeText(let text):
            for character in text {
                guard let keysym = BootCommand.keysym(for: character) else { continue }
                try client.pressKey(keysym)
                usleep(keystrokeInterval)
            }

        case .click(let text):
            try await clickText(text)
        }
    }

    // MARK: - OCR click

    /// OCRs the framebuffer looking for `text`, retrying while the screen
    /// settles, then clicks the center of the matched text.
    private func clickText(_ text: String, attempts: Int = 12, retryDelay: TimeInterval = 5) async throws {
        for attempt in 1...attempts {
            let image = try client.captureFramebuffer()
            if let center = try Self.findText(text, in: image) {
                onProgress("Found '\(text)' at (\(center.x), \(center.y)), clicking")
                try client.clickAt(x: center.x, y: center.y)
                return
            }
            if attempt < attempts {
                onProgress("'\(text)' not on screen yet (attempt \(attempt)/\(attempts))")
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
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
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let recognized = candidate.string.lowercased()
            guard recognized.contains(target) else { continue }

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
            return (x, y)
        }
        return nil
    }
}
