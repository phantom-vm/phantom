import Foundation
import CommonCrypto

// MARK: - Media Types

enum PhantomMediaType {
    static let ociManifest = "application/vnd.oci.image.manifest.v1+json"
    static let ociConfig = "application/vnd.oci.image.config.v1+json"
    static let vmConfig = "application/vnd.monk-studio.phantom.config.v1"
    static let nvram = "application/vnd.monk-studio.phantom.nvram.v1"
    static let disk = "application/vnd.monk-studio.phantom.disk.v1"
}

// MARK: - OCI Manifest

struct OCIManifest: Codable {
    let schemaVersion: Int
    let mediaType: String
    let config: OCIDescriptor
    var layers: [OCIDescriptor]

    init(config: OCIDescriptor, layers: [OCIDescriptor]) {
        self.schemaVersion = 2
        self.mediaType = PhantomMediaType.ociManifest
        self.config = config
        self.layers = layers
    }

    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func fromJSON(_ data: Data) throws -> OCIManifest {
        return try JSONDecoder().decode(OCIManifest.self, from: data)
    }
}

// MARK: - OCI Descriptor

struct OCIDescriptor: Codable {
    let mediaType: String
    let digest: String
    let size: Int64
    let annotations: [String: String]?

    init(mediaType: String, digest: String, size: Int64, annotations: [String: String]? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.annotations = annotations
    }

    /// Disk slot this layer belongs to, or nil on images written before the
    /// annotation existed (where position and index are the same thing).
    var chunkIndex: Int? {
        annotations?[PhantomAnnotation.chunkIndex].flatMap(Int.init)
    }

    static func from(data: Data, mediaType: String, annotations: [String: String]? = nil) -> OCIDescriptor {
        OCIDescriptor(
            mediaType: mediaType,
            digest: Digest.sha256(data),
            size: Int64(data.count),
            annotations: annotations
        )
    }
}

// MARK: - OCI Image Config

struct OCIImageConfig: Codable {
    let architecture: String
    let os: String

    static let `default` = OCIImageConfig(architecture: "arm64", os: "darwin")

    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Phantom VM Config (stored as a layer)

struct PhantomVMConfig: Codable {
    let version: Int
    let hardwareModelBase64: String
    let diskSize: UInt64
    /// The machine identifier (an ECID) of the VM the image was saved from.
    ///
    /// Carried in the image so a restored VM presents the same machine identity
    /// as the one that went through Setup Assistant. Give a VM a fresh ECID and
    /// macOS reads it as new hardware, and re-runs the hardware-tied Setup
    /// Assistant panes — Software Update, Apple Account, FileVault — on the next
    /// login, however complete the setup baked into the disk is.
    ///
    /// Optional: images published before this field existed decode with nil, and
    /// restore falls back to generating an identifier (and to the old behaviour).
    let machineIdentifierBase64: String?

    init(hardwareModel: Data, diskSize: UInt64, machineIdentifier: Data? = nil) {
        self.version = 1
        self.hardwareModelBase64 = hardwareModel.base64EncodedString()
        self.diskSize = diskSize
        self.machineIdentifierBase64 = machineIdentifier?.base64EncodedString()
    }

    func hardwareModelData() throws -> Data {
        guard let data = Data(base64Encoded: hardwareModelBase64) else {
            throw OCIError.invalidConfig("Failed to decode HardwareModel from base64")
        }
        return data
    }

    /// The saved machine identifier, or nil for an image from before the field
    /// was recorded.
    func machineIdentifierData() throws -> Data? {
        guard let machineIdentifierBase64 else { return nil }
        guard let data = Data(base64Encoded: machineIdentifierBase64) else {
            throw OCIError.invalidConfig("Failed to decode MachineIdentifier from base64")
        }
        return data
    }

    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func fromJSON(_ data: Data) throws -> PhantomVMConfig {
        return try JSONDecoder().decode(PhantomVMConfig.self, from: data)
    }
}

// MARK: - Annotation Keys

enum PhantomAnnotation {
    static let uncompressedSize = "vnd.monk-studio.phantom.uncompressed-size"

    /// Which 512 MB slot of the disk a chunk layer belongs to.
    ///
    /// All-zero chunks are not stored, so a disk layer's position in the
    /// manifest no longer implies its offset. Images written before this
    /// annotation existed have no gaps, so a missing value falls back to the
    /// layer's position.
    static let chunkIndex = "vnd.monk-studio.phantom.chunk-index"
}

// MARK: - Digest

nonisolated enum Digest {
    static func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}

// MARK: - Errors

enum OCIError: Error, LocalizedError {
    case invalidConfig(String)
    case invalidManifest(String)
    case invalidReference(String)
    case imageNotFound(String)
    case imageAlreadyExists(String)
    case vmNotStopped(String)
    case compressionFailed(String)
    case decompressionFailed(String)
    case digestMismatch(expected: String, actual: String)
    case diskError(String)
    case registryError(statusCode: Int, message: String)
    case authFailed(String)
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let msg): return "Invalid config: \(msg)"
        case .invalidManifest(let msg): return "Invalid manifest: \(msg)"
        case .invalidReference(let msg): return "Invalid reference: \(msg)"
        case .imageNotFound(let name): return "Image not found: \(name)"
        case .imageAlreadyExists(let name): return "Image already exists: \(name)"
        case .vmNotStopped(let id): return "VM must be stopped: \(id)"
        case .compressionFailed(let msg): return "Compression failed: \(msg)"
        case .decompressionFailed(let msg): return "Decompression failed: \(msg)"
        case .digestMismatch(let expected, let actual): return "Digest mismatch: expected \(expected), got \(actual)"
        case .diskError(let msg): return "Disk error: \(msg)"
        case .registryError(let code, let msg): return "Registry error (\(code)): \(msg)"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
        case .operationInProgress: return "An OCI operation is already in progress"
        }
    }
}

// MARK: - Image Info (for listing)

struct ImageInfo: Codable {
    let name: String
    let diskChunks: Int
    let totalSize: Int64
    let createdAt: String
    /// Where a pulled image came from, absent for one saved locally — see `PullRecord`.
    let pulledFrom: PullRecord?
}

/// Written beside a pulled image as `pulled.json`, so a later `image list` can
/// tell whether the catalog now points somewhere else.
///
/// The digest has to be recorded at pull time because nothing else preserves it:
/// pushing re-encodes the manifest, so the local `manifest.json` bytes hash to
/// something other than what the registry stored.
struct PullRecord: Codable {
    let reference: String
    let digest: String
    let pulledAt: String
}
