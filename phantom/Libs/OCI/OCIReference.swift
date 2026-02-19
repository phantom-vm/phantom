import Foundation

// MARK: - OCI Reference

/// Parses OCI image references like "ghcr.io/org/repo:tag" or "localhost:5000/repo@sha256:..."
struct OCIReference: Equatable {
    let registry: String
    let namespace: String
    let reference: String

    var isDigest: Bool { reference.hasPrefix("sha256:") }
    var tag: String? { isDigest ? nil : reference }

    /// Full string representation
    var full: String { "\(registry)/\(namespace):\(reference)" }

    /// Base URL for registry API
    var baseURL: URL {
        let proto = registry.hasPrefix("localhost") || registry.contains("localhost:") ? "http" : "https"
        return URL(string: "\(proto)://\(registry)/v2/")!
    }

    init(registry: String, namespace: String, reference: String) {
        self.registry = registry
        self.namespace = namespace
        self.reference = reference
    }

    /// Parse a reference string into components.
    ///
    /// Supported formats:
    /// - `ghcr.io/org/repo:tag`
    /// - `ghcr.io/org/repo@sha256:abc...`
    /// - `localhost:5000/repo:tag`
    /// - `registry.example.com/org/repo` (defaults to `:latest`)
    init(parsing input: String) throws {
        let str = input.trimmingCharacters(in: .whitespaces)
        guard !str.isEmpty else {
            throw OCIError.invalidReference("Reference cannot be empty")
        }

        // Split off the reference (@digest or :tag) from the right
        var remaining = str
        var ref = "latest"

        if let atIndex = remaining.lastIndex(of: "@") {
            ref = String(remaining[remaining.index(after: atIndex)...])
            remaining = String(remaining[..<atIndex])
        } else if let colonIndex = Self.findTagColon(in: remaining) {
            ref = String(remaining[remaining.index(after: colonIndex)...])
            remaining = String(remaining[..<colonIndex])
        }

        guard !ref.isEmpty else {
            throw OCIError.invalidReference("Reference (tag or digest) cannot be empty")
        }

        // Split registry from namespace
        // The first component is the registry if it contains a dot or colon (port), or is "localhost"
        let parts = remaining.split(separator: "/", maxSplits: 1).map(String.init)

        guard parts.count >= 2 else {
            throw OCIError.invalidReference("Reference must include registry and namespace: \(input)")
        }

        let registryCandidate = parts[0]
        let namespaceCandidate = parts[1]

        guard Self.looksLikeRegistry(registryCandidate) else {
            throw OCIError.invalidReference("'\(registryCandidate)' doesn't look like a registry host")
        }

        guard !namespaceCandidate.isEmpty else {
            throw OCIError.invalidReference("Namespace cannot be empty")
        }

        self.registry = registryCandidate
        self.namespace = namespaceCandidate
        self.reference = ref
    }

    /// Find the colon that separates the tag (not a port colon).
    /// The tag colon is the last colon that appears after the last `/`.
    private static func findTagColon(in str: String) -> String.Index? {
        guard let lastSlash = str.lastIndex(of: "/") else {
            // No slash at all — could be `host:port` which has no tag
            return nil
        }
        let afterSlash = str[str.index(after: lastSlash)...]
        if let colonInName = afterSlash.lastIndex(of: ":") {
            return colonInName
        }
        return nil
    }

    /// Check if a string looks like a registry hostname (has a dot, colon, or is "localhost").
    private static func looksLikeRegistry(_ s: String) -> Bool {
        s.contains(".") || s.contains(":") || s == "localhost"
    }
}
