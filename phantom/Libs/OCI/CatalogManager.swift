import Foundation

// MARK: - Catalog Types

/// One published image, as the catalog artifact describes it. Mirrors
/// `CatalogEntry` in the CLI's `lib/catalog.ts` — same artifact, two readers.
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
/// The catalog is a one-layer OCI artifact in the same registry as the images —
/// see the CLI's `lib/catalog.ts`, which reads the same object. Reads are
/// anonymous, so a fresh install can browse before it has credentials.
///
/// It only *points*: every entry carries its image's manifest digest, and pulls
/// go by digest, so the trust in the catalog never exceeds the trust in the
/// digests it names.
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
    static var reference: String {
        ProcessInfo.processInfo.environment["PHANTOM_CATALOG"] ?? "ghcr.io/phantom-vm/catalog:latest"
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

        let reference = Self.reference
        state = .loading

        do {
            let catalog = try await Task.detached { () -> Catalog in
                let ref = try OCIReference(parsing: reference)
                let creds = RegistryCredentials.load(for: ref.registry)
                let client = OCIRegistryClient(reference: ref, credentials: creds)

                let (manifest, _) = try await client.pullManifest(reference: ref.reference)
                guard let layer = manifest.layers.first else {
                    throw OCIError.invalidManifest("catalog artifact has no layers")
                }

                // pullBlob verifies the blob against the digest the manifest names.
                let data = try await client.pullBlob(digest: layer.digest)
                return try JSONDecoder().decode(Catalog.self, from: data)
            }.value

            guard catalog.schemaVersion == 1 else {
                throw OCIError.invalidManifest("unsupported catalog schemaVersion \(catalog.schemaVersion)")
            }

            state = .loaded(catalog.images)
            log("Loaded catalog: \(catalog.images.count) images")
        } catch {
            state = .error(error.localizedDescription)
            log("Failed to load catalog from \(reference): \(error.localizedDescription)")
        }
    }
}
