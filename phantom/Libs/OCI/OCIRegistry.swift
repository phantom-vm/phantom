import Foundation

// MARK: - OCI Registry Client

/// HTTP client for the OCI Distribution Spec API.
class OCIRegistryClient {
    let reference: OCIReference
    private let auth: OCIAuth
    private let session: URLSession

    init(reference: OCIReference, credentials: RegistryCredentials?) {
        self.reference = reference
        self.auth = OCIAuth(credentials: credentials)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    // MARK: - Blob Operations

    /// Check if a blob exists in the registry.
    func blobExists(digest: String) async throws -> Bool {
        let url = endpointURL("\(reference.namespace)/blobs/\(digest)")
        let (_, response) = try await authenticatedRequest(.HEAD, url: url)

        switch response.statusCode {
        case 200: return true
        case 404: return false
        default:
            throw OCIError.registryError(statusCode: response.statusCode, message: "checking blob")
        }
    }

    /// Upload a blob to the registry.
    func pushBlob(data: Data, digest: String) async throws {
        // Initiate upload
        let initiateURL = endpointURL("\(reference.namespace)/blobs/uploads/")
        let (_, initiateResponse) = try await authenticatedRequest(.POST, url: initiateURL, headers: ["Content-Length": "0"])

        guard initiateResponse.statusCode == 202 else {
            throw OCIError.registryError(statusCode: initiateResponse.statusCode, message: "initiating blob upload")
        }

        guard let locationHeader = initiateResponse.value(forHTTPHeaderField: "Location") else {
            throw OCIError.registryError(statusCode: 0, message: "missing Location header in upload response")
        }

        // Resolve location URL (may be relative or absolute)
        guard let uploadURL = resolveLocation(locationHeader) else {
            throw OCIError.registryError(statusCode: 0, message: "invalid upload Location: \(locationHeader)")
        }

        // Monolithic upload
        var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: true)!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "digest", value: digest))
        components.queryItems = queryItems

        let (_, putResponse) = try await authenticatedRequest(
            .PUT,
            url: components.url!,
            headers: ["Content-Type": "application/octet-stream"],
            body: data
        )

        guard putResponse.statusCode == 201 else {
            throw OCIError.registryError(statusCode: putResponse.statusCode, message: "uploading blob")
        }
    }

    /// Download a blob from the registry.
    func pullBlob(digest: String) async throws -> Data {
        let url = endpointURL("\(reference.namespace)/blobs/\(digest)")
        let (data, response) = try await authenticatedRequest(.GET, url: url)

        guard response.statusCode == 200 else {
            throw OCIError.registryError(statusCode: response.statusCode, message: "pulling blob \(digest)")
        }

        // Verify digest
        let actualDigest = Digest.sha256(data)
        guard actualDigest == digest else {
            throw OCIError.digestMismatch(expected: digest, actual: actualDigest)
        }

        return data
    }

    // MARK: - Manifest Operations

    /// Push a manifest to the registry.
    func pushManifest(_ manifest: OCIManifest, reference ref: String) async throws {
        let url = endpointURL("\(reference.namespace)/manifests/\(ref)")
        let manifestData = try manifest.toJSON()

        let (_, response) = try await authenticatedRequest(
            .PUT,
            url: url,
            headers: ["Content-Type": PhantomMediaType.ociManifest],
            body: manifestData
        )

        guard response.statusCode == 201 else {
            throw OCIError.registryError(statusCode: response.statusCode, message: "pushing manifest")
        }
    }

    /// Pull a manifest from the registry.
    /// Returns the manifest along with the digest of the bytes received, which
    /// is the digest the registry stores — the caller records it so a later
    /// `image list` can tell a pulled image from the one now published.
    func pullManifest(reference ref: String) async throws -> (manifest: OCIManifest, digest: String) {
        let url = endpointURL("\(reference.namespace)/manifests/\(ref)")

        let (data, response) = try await authenticatedRequest(
            .GET,
            url: url,
            headers: ["Accept": PhantomMediaType.ociManifest]
        )

        guard response.statusCode == 200 else {
            throw OCIError.registryError(statusCode: response.statusCode, message: "pulling manifest")
        }

        // Pulling by digest is the only self-verifying form: the digest names
        // the exact bytes, so a registry (or anything between) cannot swap the
        // manifest — and since every layer digest is checked on pull, verifying
        // the manifest extends that guarantee to the whole image. A tag pull has
        // nothing to check against; the catalog therefore records digests.
        let digest = Digest.sha256(data)
        if ref.hasPrefix("sha256:") {
            guard digest == ref else {
                throw OCIError.digestMismatch(expected: ref, actual: digest)
            }
        }

        return (try OCIManifest.fromJSON(data), digest)
    }

    // MARK: - HTTP Layer

    private enum HTTPMethod: String {
        case GET, POST, PUT, PATCH, HEAD
    }

    private func authenticatedRequest(
        _ method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        // First attempt
        var (data, response) = try await rawRequest(method, url: url, headers: headers, body: body)

        // Handle 401 — negotiate auth and retry
        if response.statusCode == 401 {
            if let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate") ?? response.value(forHTTPHeaderField: "Www-Authenticate") {
                try await auth.handleChallenge(wwwAuthenticate: wwwAuth, namespace: reference.namespace)
                (data, response) = try await rawRequest(method, url: url, headers: headers, body: body)
            }
        }

        return (data, response)
    }

    private func rawRequest(
        _ method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let authHeader = auth.authorizationHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        request.setValue("Phantom/1.0", forHTTPHeaderField: "User-Agent")

        if let body = body {
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.registryError(statusCode: 0, message: "not an HTTP response")
        }

        return (data, httpResponse)
    }

    // MARK: - URL Helpers

    private func endpointURL(_ path: String) -> URL {
        URL(string: path, relativeTo: reference.baseURL)!.absoluteURL
    }

    private func resolveLocation(_ location: String) -> URL? {
        if let url = URL(string: location), url.host != nil {
            return url
        }
        // Relative URL
        return URL(string: location, relativeTo: reference.baseURL)?.absoluteURL
    }
}
