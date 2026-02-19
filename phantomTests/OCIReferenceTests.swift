import Foundation
import Testing
@testable import phantom

struct OCIReferenceTests {

    // MARK: - Valid References

    @Test func parseFullReference() throws {
        let ref = try OCIReference(parsing: "ghcr.io/monk-studio/macos-base:latest")
        #expect(ref.registry == "ghcr.io")
        #expect(ref.namespace == "monk-studio/macos-base")
        #expect(ref.reference == "latest")
        #expect(ref.isDigest == false)
    }

    @Test func parseWithTag() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1.2.3")
        #expect(ref.registry == "ghcr.io")
        #expect(ref.namespace == "org/repo")
        #expect(ref.reference == "v1.2.3")
        #expect(ref.tag == "v1.2.3")
    }

    @Test func parseDigestReference() throws {
        let digest = "sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let ref = try OCIReference(parsing: "ghcr.io/org/repo@\(digest)")
        #expect(ref.registry == "ghcr.io")
        #expect(ref.namespace == "org/repo")
        #expect(ref.reference == digest)
        #expect(ref.isDigest == true)
        #expect(ref.tag == nil)
    }

    @Test func parseLocalhostWithPort() throws {
        let ref = try OCIReference(parsing: "localhost:5000/test/myvm:v1")
        #expect(ref.registry == "localhost:5000")
        #expect(ref.namespace == "test/myvm")
        #expect(ref.reference == "v1")
    }

    @Test func parseLocalhostWithPortDefaultTag() throws {
        let ref = try OCIReference(parsing: "localhost:5000/test/myvm")
        #expect(ref.registry == "localhost:5000")
        #expect(ref.namespace == "test/myvm")
        #expect(ref.reference == "latest")
    }

    @Test func parseDefaultsToLatest() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo")
        #expect(ref.reference == "latest")
    }

    @Test func parseCustomRegistry() throws {
        let ref = try OCIReference(parsing: "registry.example.com/team/image:prod")
        #expect(ref.registry == "registry.example.com")
        #expect(ref.namespace == "team/image")
        #expect(ref.reference == "prod")
    }

    @Test func parseSingleNamespace() throws {
        let ref = try OCIReference(parsing: "ghcr.io/myimage:v1")
        #expect(ref.registry == "ghcr.io")
        #expect(ref.namespace == "myimage")
        #expect(ref.reference == "v1")
    }

    @Test func parseDeepNamespace() throws {
        let ref = try OCIReference(parsing: "ghcr.io/a/b/c/d:tag")
        #expect(ref.registry == "ghcr.io")
        #expect(ref.namespace == "a/b/c/d")
        #expect(ref.reference == "tag")
    }

    // MARK: - Base URL

    @Test func baseURLUsesHTTPS() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        #expect(ref.baseURL.absoluteString == "https://ghcr.io/v2/")
    }

    @Test func baseURLUsesHTTPForLocalhost() throws {
        let ref = try OCIReference(parsing: "localhost:5000/repo:v1")
        #expect(ref.baseURL.absoluteString == "http://localhost:5000/v2/")
    }

    // MARK: - Invalid References

    @Test func emptyStringThrows() {
        #expect(throws: OCIError.self) {
            _ = try OCIReference(parsing: "")
        }
    }

    @Test func noRegistryThrows() {
        #expect(throws: OCIError.self) {
            _ = try OCIReference(parsing: "justarepo:latest")
        }
    }

    @Test func noNamespaceThrows() {
        #expect(throws: OCIError.self) {
            _ = try OCIReference(parsing: "ghcr.io")
        }
    }

    // MARK: - Equality

    @Test func equalReferences() throws {
        let a = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        let b = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        #expect(a == b)
    }

    @Test func differentTagsNotEqual() throws {
        let a = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        let b = try OCIReference(parsing: "ghcr.io/org/repo:v2")
        #expect(a != b)
    }
}
