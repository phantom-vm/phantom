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

    init(hardwareModel: Data, diskSize: UInt64) {
        self.version = 1
        self.hardwareModelBase64 = hardwareModel.base64EncodedString()
        self.diskSize = diskSize
    }

    func hardwareModelData() throws -> Data {
        guard let data = Data(base64Encoded: hardwareModelBase64) else {
            throw OCIError.invalidConfig("Failed to decode HardwareModel from base64")
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
}
