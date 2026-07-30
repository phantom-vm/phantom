import Foundation
import Testing
@testable import Phantom

/// An image name becomes a directory name under `images/`, so anything the
/// name rule lets through is a path the daemon will write to. The GUI checks
/// before it asks; the API and the CLI pass on whatever they were handed, which
/// is why the check has to be in the manager itself.
@MainActor
struct ImageNameTests {

    /// A manager over a fresh temp `images/`, with a sibling directory standing
    /// in for "somewhere outside" that a traversing name could reach.
    private struct Fixture {
        let root: URL
        let imagesDir: URL
        let outsideDir: URL
        let manager: OCIImageManager

        @MainActor init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("phantom-image-name-tests-\(UUID().uuidString)")
            imagesDir = root.appendingPathComponent("images")
            outsideDir = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
            manager = OCIImageManager(imagesDir: imagesDir, log: { _ in })
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - The Rule

    @Test func acceptsOrdinaryNames() throws {
        for name in ["tahoe-base", "xcode-26-6", "a", "with_underscore", "MixedCase123"] {
            try OCIImageManager.validate(name: name)
        }
    }

    @Test func rejectsNamesThatLeaveTheImagesDirectory() {
        for name in ["..", "../..", "../outside", "a/b", "/etc/passwd", "./x"] {
            #expect(throws: OCIError.self) { try OCIImageManager.validate(name: name) }
        }
    }

    @Test func rejectsNamesThatAreNotOne() {
        #expect(throws: OCIError.self) { try OCIImageManager.validate(name: "") }
        #expect(throws: OCIError.self) { try OCIImageManager.validate(name: "has space") }
        #expect(throws: OCIError.self) { try OCIImageManager.validate(name: "tahoe.base") }
        #expect(throws: OCIError.self) { try OCIImageManager.validate(name: "café") }
        #expect(throws: OCIError.self) { try OCIImageManager.validate(name: String(repeating: "a", count: 65)) }
    }

    @Test func acceptsANameOfExactlyTheMaximumLength() throws {
        try OCIImageManager.validate(name: String(repeating: "a", count: 64))
    }

    // MARK: - The Operations That Write

    /// `save` reports through `state` rather than throwing, so a refused name
    /// has to show up there — and nothing may be written on the way.
    @Test func saveRefusesATraversingName() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        await f.manager.save(
            name: "../outside/stolen",
            bundlePath: f.root.appendingPathComponent("some-vm"),
            replace: true
        )

        guard case .error(let message) = f.manager.state else {
            Issue.record("expected an error state, got \(f.manager.state)")
            return
        }
        #expect(message.contains("Invalid image name"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.outsideDir.path).isEmpty)
    }

    @Test func pullRefusesATraversingName() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        // Refused before the reference is even parsed — so no network, and the
        // failure path that deletes the named directory is never reached.
        await f.manager.pull(
            reference: "ghcr.io/monk-studio/phantom-images/tahoe-base:latest",
            name: "../outside",
            username: nil,
            password: nil,
            replace: true
        )

        guard case .error(let message) = f.manager.state else {
            Issue.record("expected an error state, got \(f.manager.state)")
            return
        }
        #expect(message.contains("Invalid image name"))
        #expect(FileManager.default.fileExists(atPath: f.outsideDir.path))
    }

    @Test func deleteRefusesATraversingName() throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        let victim = f.outsideDir.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)

        #expect(throws: OCIError.self) { try f.manager.delete(name: "../outside/keep-me") }
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func restoreRefusesATraversingName() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        await #expect(throws: OCIError.self) {
            try await f.manager.restore(
                image: "../outside",
                into: f.root.appendingPathComponent("bundle"),
                progress: { _ in }
            )
        }
    }

    // MARK: - The Lookups Callers Gate On

    /// `imageExists` is what the API asks before a push and a restore. A name
    /// that escapes the images directory is not an image, whatever is at the
    /// path it points to.
    @Test func imageExistsIsFalseForANameThatEscapes() throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        let decoy = f.outsideDir.appendingPathComponent("decoy")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: decoy.appendingPathComponent("manifest.json"))

        #expect(f.manager.imageExists("../outside/decoy") == false)
    }

    @Test func imageDirectoryStaysUnderTheImagesDirectory() throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        let dir = try f.manager.imageDirectory(for: "tahoe-base")
        #expect(dir == f.imagesDir.appendingPathComponent("tahoe-base"))
        #expect(throws: OCIError.self) { try f.manager.imageDirectory(for: "../outside") }
    }
}
