import Foundation
import Testing
@testable import Phantom

struct OCITypesTests {

    // MARK: - Digest

    @Test func sha256EmptyData() {
        let digest = Digest.sha256(Data())
        #expect(digest == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256KnownValue() {
        let data = "hello".data(using: .utf8)!
        let digest = Digest.sha256(data)
        #expect(digest == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func sha256Deterministic() {
        let data = "test data".data(using: .utf8)!
        let a = Digest.sha256(data)
        let b = Digest.sha256(data)
        #expect(a == b)
    }

    // MARK: - OCIDescriptor

    @Test func descriptorFromData() {
        let data = "test".data(using: .utf8)!
        let desc = OCIDescriptor.from(data: data, mediaType: "application/octet-stream")
        #expect(desc.mediaType == "application/octet-stream")
        #expect(desc.size == 4)
        #expect(desc.digest == Digest.sha256(data))
        #expect(desc.annotations == nil)
    }

    @Test func descriptorWithAnnotations() {
        let data = Data([0x01, 0x02])
        let desc = OCIDescriptor.from(
            data: data,
            mediaType: PhantomMediaType.disk,
            annotations: [PhantomAnnotation.uncompressedSize: "1024"]
        )
        #expect(desc.annotations?[PhantomAnnotation.uncompressedSize] == "1024")
    }

    // MARK: - OCIManifest

    @Test func manifestRoundTrip() throws {
        let config = OCIDescriptor(mediaType: PhantomMediaType.ociConfig, digest: "sha256:abc", size: 50)
        let layer = OCIDescriptor(mediaType: PhantomMediaType.vmConfig, digest: "sha256:def", size: 100)
        let manifest = OCIManifest(config: config, layers: [layer])

        let json = try manifest.toJSON()
        let decoded = try OCIManifest.fromJSON(json)

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.mediaType == PhantomMediaType.ociManifest)
        #expect(decoded.config.digest == "sha256:abc")
        #expect(decoded.layers.count == 1)
        #expect(decoded.layers[0].mediaType == PhantomMediaType.vmConfig)
    }

    // MARK: - OCIImageConfig

    @Test func imageConfigDefault() throws {
        let config = OCIImageConfig.default
        #expect(config.architecture == "arm64")
        #expect(config.os == "darwin")

        let json = try config.toJSON()
        let decoded = try JSONDecoder().decode(OCIImageConfig.self, from: json)
        #expect(decoded.architecture == "arm64")
        #expect(decoded.os == "darwin")
    }

    // MARK: - PhantomVMConfig

    @Test func vmConfigRoundTrip() throws {
        let hwData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let config = PhantomVMConfig(hardwareModel: hwData, diskSize: 68_719_476_736)

        let json = try config.toJSON()
        let decoded = try PhantomVMConfig.fromJSON(json)

        #expect(decoded.version == 1)
        #expect(decoded.diskSize == 68_719_476_736)
        let decodedHW = try decoded.hardwareModelData()
        #expect(decodedHW == hwData)
    }

    @Test func vmConfigCarriesMachineIdentifier() throws {
        let hwData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let idData = Data([0x01, 0x02, 0x03, 0x04])
        let config = PhantomVMConfig(
            hardwareModel: hwData,
            diskSize: 68_719_476_736,
            machineIdentifier: idData
        )

        let decoded = try PhantomVMConfig.fromJSON(try config.toJSON())

        #expect(try decoded.machineIdentifierData() == idData)
    }

    // An image saved before the identifier was recorded has no such key; it must
    // still decode, with nil standing for "restore has to generate one".
    @Test func vmConfigWithoutMachineIdentifierDecodesToNil() throws {
        let json = """
        {"version":1,"hardwareModelBase64":"3q2+7w==","diskSize":0}
        """.data(using: .utf8)!

        let config = try PhantomVMConfig.fromJSON(json)

        #expect(try config.machineIdentifierData() == nil)
    }

    @Test func vmConfigInvalidBase64Throws() throws {
        // Create a config with invalid base64 by encoding then mutating the JSON
        let json = """
        {"version":1,"hardwareModelBase64":"not-valid-base64!!!","diskSize":0}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(PhantomVMConfig.self, from: json)
        #expect(throws: OCIError.self) {
            _ = try config.hardwareModelData()
        }
    }
}
