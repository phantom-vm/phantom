import Foundation

// MARK: - OCI Auth

/// Handles OCI registry authentication (Bearer token and Basic auth).
class OCIAuth {
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private let credentials: RegistryCredentials?

    init(credentials: RegistryCredentials?) {
        self.credentials = credentials
    }

    /// Get an authorization header value for requests.
    /// Returns nil if no auth is available yet (first request triggers auth).
    func authorizationHeader() -> String? {
        if let token = cachedToken {
            if let expiresAt = tokenExpiresAt, Date() >= expiresAt {
                return nil // Token expired
            }
            return "Bearer \(token)"
        }
        if let creds = credentials {
            return "Basic \(creds.basicAuthEncoded)"
        }
        return nil
    }

    /// Handle a 401 response by negotiating a token.
    /// - Parameter wwwAuthenticate: The WWW-Authenticate header value
    func handleChallenge(wwwAuthenticate: String, namespace: String) async throws {
        let challenge = try WWWAuthenticateChallenge(rawValue: wwwAuthenticate)

        if challenge.scheme.lowercased() == "basic" {
            // Basic auth — credentials are already in authorizationHeader()
            return
        }

        guard challenge.scheme.lowercased() == "bearer" else {
            throw OCIError.authFailed("Unsupported auth scheme: \(challenge.scheme)")
        }

        guard let realm = challenge.params["realm"] else {
            throw OCIError.authFailed("Missing realm in WWW-Authenticate header")
        }

        guard var urlComponents = URLComponents(string: realm) else {
            throw OCIError.authFailed("Invalid realm URL: \(realm)")
        }

        // Add scope and service params from challenge
        var queryItems: [URLQueryItem] = []
        if let service = challenge.params["service"] {
            queryItems.append(URLQueryItem(name: "service", value: service))
        }
        if let scope = challenge.params["scope"] {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        if !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw OCIError.authFailed("Failed to construct token URL")
        }

        var request = URLRequest(url: url)
        if let creds = credentials {
            request.setValue("Basic \(creds.basicAuthEncoded)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OCIError.authFailed("Token request failed with status \(statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = tokenResponse.token ?? tokenResponse.accessToken

        if let expiresIn = tokenResponse.expiresIn {
            tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            tokenExpiresAt = Date().addingTimeInterval(60) // Default 60s
        }
    }

    /// Clear cached auth state
    func reset() {
        cachedToken = nil
        tokenExpiresAt = nil
    }
}

// MARK: - Credentials

struct RegistryCredentials {
    let username: String
    let password: String

    var basicAuthEncoded: String {
        let raw = "\(username):\(password)"
        return Data(raw.utf8).base64EncodedString()
    }

    /// Load credentials from environment variables or Docker config.
    static func load(for registry: String, username: String? = nil, password: String? = nil) -> RegistryCredentials? {
        // Explicit credentials take priority
        if let username = username, let password = password {
            return RegistryCredentials(username: username, password: password)
        }

        // Environment variables
        if let envUser = ProcessInfo.processInfo.environment["PHANTOM_REGISTRY_USERNAME"],
           let envPass = ProcessInfo.processInfo.environment["PHANTOM_REGISTRY_PASSWORD"] {
            return RegistryCredentials(username: envUser, password: envPass)
        }

        // Docker config
        if let creds = loadFromDockerConfig(registry: registry) {
            return creds
        }

        return nil
    }

    private static func loadFromDockerConfig(registry: String) -> RegistryCredentials? {
        let dockerConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker/config.json")

        guard let data = try? Data(contentsOf: dockerConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auths = json["auths"] as? [String: Any] else {
            return nil
        }

        // Try exact match first, then try with/without https://
        let candidates = [registry, "https://\(registry)", "http://\(registry)"]

        for candidate in candidates {
            if let authEntry = auths[candidate] as? [String: Any],
               let auth = authEntry["auth"] as? String,
               let decoded = Data(base64Encoded: auth),
               let decodedString = String(data: decoded, encoding: .utf8) {
                let parts = decodedString.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return RegistryCredentials(username: String(parts[0]), password: String(parts[1]))
                }
            }
        }

        return nil
    }
}

// MARK: - WWW-Authenticate Challenge Parser

struct WWWAuthenticateChallenge {
    let scheme: String
    let params: [String: String]

    init(rawValue: String) throws {
        let splits = rawValue.split(separator: " ", maxSplits: 1)
        guard splits.count == 2 else {
            throw OCIError.authFailed("Malformed WWW-Authenticate header")
        }

        self.scheme = String(splits[0])

        // Parse key=value directives (comma-separated, values may be quoted)
        var parsed: [String: String] = [:]
        var remaining = String(splits[1])

        // Simple parser handling quoted values
        var inQuote = false
        var current = ""
        var pairs: [String] = []

        for ch in remaining {
            if ch == "\"" {
                inQuote.toggle()
            } else if ch == "," && !inQuote {
                pairs.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            pairs.append(current.trimmingCharacters(in: .whitespaces))
        }

        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
                var value = String(kv[1]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                parsed[key] = value
            }
        }

        self.params = parsed
    }
}

// MARK: - Token Response

private struct TokenResponse: Codable {
    let token: String?
    let accessToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case token
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
