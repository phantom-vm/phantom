import Foundation

// MARK: - Catalog Types

/// One published image, as the catalog describes it. Mirrors `CatalogEntry` in
/// the CLI's `lib/catalog.ts` — same file, two readers.
struct CatalogEntry: Codable, Identifiable, Equatable {
    /// Local image name this is pulled as, and how users refer to it
    let name: String
    let description: String
    /// Repository without a tag, e.g. "ghcr.io/phantom-vm/xcode-26-6"
    let repository: String
    /// Manifest digest — pulls use this, not the tag
    let digest: String
    /// Sum of the compressed layers, for display
    let compressedSize: Int64
    /// Uncompressed disk size of the VM the image restores to
    let diskSize: Int64
    /// ISO date the image was published
    let published: String

    var id: String { name }

    /// Reference to pull this entry by: its repository pinned to the digest, so
    /// a retagged or tampered registry can't substitute another image.
    var pullReference: String { "\(repository)@\(digest)" }
}

struct Catalog: Codable {
    let schemaVersion: Int
    let images: [CatalogEntry]
}

// MARK: - Catalog Manager

/// Fetches the published image catalog so the GUI can show what exists before
/// anything has been pulled.
///
/// The catalog is `catalog.json` at the root of the phantom repo, fetched over
/// HTTPS — see the CLI's `lib/catalog.ts`, which reads the same file. Reads are
/// anonymous, so a fresh install can browse before it has credentials.
///
/// It only *points*: every entry carries its image's manifest digest, and pulls
/// go by digest, so the trust in the catalog never exceeds the trust in the
/// digests it names. That is why this fetch needs no integrity check of its
/// own — being wrong about the catalog can misname or mislist an image, but it
/// cannot make the daemon accept bytes that don't match a digest.
@Observable
@MainActor
class CatalogManager {
    enum State: Equatable {
        case idle
        case loading
        case loaded([CatalogEntry])
        case error(String)
    }

    private(set) var state: State = .idle

    private let log: (String) -> Void

    /// Overridable for the same reason the CLI overrides it: pointing a test or
    /// a private deployment at another catalog without a rebuild.
    static var url: String {
        ProcessInfo.processInfo.environment["PHANTOM_CATALOG"]
            ?? "https://raw.githubusercontent.com/phantom-vm/phantom/main/catalog.json"
    }

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    var entries: [CatalogEntry] {
        if case .loaded(let entries) = state { return entries }
        return []
    }

    /// Fetch the catalog, unless a fetch is already running.
    func load() async {
        guard state != .loading else { return }

        let source = Self.url
        state = .loading

        do {
            let catalog = try await Task.detached { () -> Catalog in
                guard let url = URL(string: source) else {
                    throw CatalogError.badSource(source)
                }

                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                // raw.githubusercontent caches for a few minutes, and URLSession
                // would happily add its own on top. The catalog changes rarely
                // but when it does, a stale listing sends a pull at a digest
                // that may already be superseded.
                request.cachePolicy = .reloadIgnoringLocalCacheData

                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw CatalogError.httpStatus(http.statusCode)
                }
                return try JSONDecoder().decode(Catalog.self, from: data)
            }.value

            guard catalog.schemaVersion == 1 else {
                throw CatalogError.unsupportedSchema(catalog.schemaVersion)
            }

            state = .loaded(catalog.images)
            log("Loaded catalog: \(catalog.images.count) images")
        } catch {
            state = .error(error.localizedDescription)
            log("Failed to load catalog from \(source): \(error.localizedDescription)")
        }
    }
}

enum CatalogError: LocalizedError {
    case badSource(String)
    case httpStatus(Int)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .badSource(let source):
            return "'\(source)' is not a URL"
        case .httpStatus(let code):
            return "catalog fetch returned HTTP \(code)"
        case .unsupportedSchema(let version):
            return "unsupported catalog schemaVersion \(version)"
        }
    }
}
