import Foundation
import Network
import Testing
@testable import Phantom

/// Cancelling an image operation has to do two things a caller can check: stop
/// the transfer, and leave the images directory as if it had never started —
/// a half-written image that `image list` can see is exactly what quitting the
/// daemon mid-pull used to leave behind.
@MainActor
struct ImageCancelTests {

    /// A manager over a fresh temp `images/`.
    private struct Fixture {
        let root: URL
        let imagesDir: URL
        let manager: OCIImageManager

        @MainActor init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("phantom-image-cancel-tests-\(UUID().uuidString)")
            imagesDir = root.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            manager = OCIImageManager(imagesDir: imagesDir, log: { _ in })
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Waits for `condition`, so a test never has to guess how long the pull
    /// takes to get going. Returns false if it never comes true.
    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Nothing Running

    @Test func cancelDoesNothingWhenNoOperationIsRunning() throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        #expect(f.manager.cancel() == nil)
        #expect(f.manager.state == .idle)
        #expect(f.manager.isCancelling == false)
    }

    // MARK: - Cancelling a Pull

    /// End to end against a registry that accepts the connection and never
    /// answers — the interesting case, since the pull is then parked inside
    /// URLSession rather than between chunks.
    @Test func cancellingAPullStopsItAndRemovesThePartialImage() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        let registry = try StalledRegistry()
        defer { registry.stop() }
        let port = try #require(await registry.port())

        let pull = Task {
            await f.manager.pull(
                reference: "localhost:\(port)/phantom/cancel-me:latest",
                name: "cancel-me",
                username: "unused",
                password: "unused",
                replace: false
            )
        }

        let running = await waitFor { if case .pulling = f.manager.state { true } else { false } }
        #expect(running, "the pull never started")

        // The directory is claimed before the transfer begins — this is what a
        // cancel has to clean up.
        let imageDir = f.imagesDir.appendingPathComponent("cancel-me")
        #expect(FileManager.default.fileExists(atPath: imageDir.path))

        #expect(f.manager.cancel() == "pull")
        #expect(f.manager.isCancelling)

        await pull.value

        guard case .cancelled(let message) = f.manager.state else {
            Issue.record("expected a cancelled state, got \(f.manager.state)")
            return
        }
        #expect(message.contains("cancel-me"))
        #expect(!FileManager.default.fileExists(atPath: imageDir.path))
        #expect(f.manager.isCancelling == false)

        // Terminal, so the next operation is free to start, and dismissible the
        // way a failure is.
        f.manager.clearTerminalState()
        #expect(f.manager.state == .idle)
    }

    // MARK: - Failing a Pull

    /// The cleanup only ever removes a directory the pull itself claimed. A pull
    /// that is refused *because* the name is taken must not delete the image it
    /// was refused over.
    @Test func aRefusedPullLeavesTheExistingImageAlone() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        let existing = f.imagesDir.appendingPathComponent("keeper")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: existing.appendingPathComponent("manifest.json"))

        // Port 1 is never listening: if this reached the network at all, the
        // failure would be a connection error rather than the refusal below.
        await f.manager.pull(
            reference: "localhost:1/phantom/keeper:latest",
            name: "keeper",
            username: nil,
            password: nil,
            replace: false
        )

        guard case .error(let message) = f.manager.state else {
            Issue.record("expected an error state, got \(f.manager.state)")
            return
        }
        #expect(message.contains("already exists"))
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("manifest.json").path))
    }
}

// MARK: - Stalled Registry

/// Accepts TCP connections and answers nothing, so a request made to it stays
/// in flight until the caller gives up — which is the point: the test decides
/// when the pull stops, not the network.
private final class StalledRegistry: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "phantom.tests.stalled-registry")
    /// Held only so the accepted connections stay open; dropping them would
    /// close the socket and hand the pull an error instead of silence.
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.connections.append(connection) }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    /// The port the listener settled on, once it is up.
    func port(timeout: Duration = .seconds(5)) async -> UInt16? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return listener.port?.rawValue
    }

    func stop() {
        listener.cancel()
        queue.async { self.connections.forEach { $0.cancel() }; self.connections = [] }
    }
}
