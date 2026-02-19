import Foundation
import Virtualization

// MARK: - OCI Image Manager

@MainActor
@Observable
class OCIImageManager {

    // MARK: - State

    enum OperationState: Equatable {
        case idle
        case saving(progress: Double, message: String)
        case pushing(progress: Double, message: String)
        case pulling(progress: Double, message: String)
        case completed(message: String)
        case error(String)

        static func == (lhs: OperationState, rhs: OperationState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.saving(let a, let am), .saving(let b, let bm)): return a == b && am == bm
            case (.pushing(let a, let am), .pushing(let b, let bm)): return a == b && am == bm
            case (.pulling(let a, let am), .pulling(let b, let bm)): return a == b && am == bm
            case (.completed(let a), .completed(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: OperationState = .idle

    // MARK: - Storage

    private let imagesDir: URL
    private let log: (String) -> Void

    init(imagesDir: URL, log: @escaping (String) -> Void) {
        self.imagesDir = imagesDir
        self.log = log
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - Save VM as Image

    /// Save a VM bundle as a local OCI image.
    /// - Parameters:
    ///   - name: Image name
    ///   - bundlePath: Path to the VM bundle directory
    func save(name: String, bundlePath: URL) async {
        guard state == .idle || isTerminalState else {
            state = .error("An operation is already in progress")
            return
        }

        state = .saving(progress: 0, message: "Preparing...")
        log("Saving VM to image '\(name)'...")

        let imageDir = imagesDir.appendingPathComponent(name)
        let diskDir = imageDir.appendingPathComponent("disk")

        do {
            // Run all heavy I/O on a background thread
            let updateProgress: @Sendable (Double, String) -> Void = { [weak self] progress, message in
                Task { @MainActor [weak self] in
                    self?.state = .saving(progress: progress, message: message)
                }
            }
            let bgLog: @Sendable (String) -> Void = { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.log(msg)
                }
            }

            let chunkMetadata = try await Task.detached { () -> [OCIDiskLayerizer.ChunkMetadata] in
                if FileManager.default.fileExists(atPath: imageDir.path) {
                    throw OCIError.imageAlreadyExists(name)
                }

                try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)

                // Read HardwareModel
                let hwPath = bundlePath.appendingPathComponent("HardwareModel")
                let hwData = try Data(contentsOf: hwPath)

                // Get disk size
                let diskPath = bundlePath.appendingPathComponent("disk.img")
                let diskAttrs = try FileManager.default.attributesOfItem(atPath: diskPath.path)
                let diskSize = diskAttrs[.size] as? UInt64 ?? 0

                // Write VM config (with HardwareModel embedded)
                let vmConfig = PhantomVMConfig(hardwareModel: hwData, diskSize: diskSize)
                let configData = try vmConfig.toJSON()
                let configPath = imageDir.appendingPathComponent("config.json")
                try configData.write(to: configPath)

                // Copy NVRAM
                let auxPath = bundlePath.appendingPathComponent("AuxiliaryStorage")
                let nvramPath = imageDir.appendingPathComponent("nvram.bin")
                try FileManager.default.copyItem(at: auxPath, to: nvramPath)

                // Chunk disk image (writes each chunk to disk immediately)
                bgLog("Chunking disk image...")
                let metadata = try OCIDiskLayerizer.chunkDisk(at: diskPath, outputDir: diskDir) { progress in
                    let overall = 0.1 + progress * 0.8
                    updateProgress(overall, "Compressing chunk \(Int(progress * 100))%")
                }

                return metadata
            }.value

            // Back on MainActor — build manifest from metadata (lightweight)
            state = .saving(progress: 0.95, message: "Writing manifest...")

            let configPath = imageDir.appendingPathComponent("config.json")
            let configData = try Data(contentsOf: configPath)
            let nvramPath = imageDir.appendingPathComponent("nvram.bin")
            let nvramData = try Data(contentsOf: nvramPath)

            let ociConfigData = try OCIImageConfig.default.toJSON()
            let ociConfigDesc = OCIDescriptor.from(data: ociConfigData, mediaType: PhantomMediaType.ociConfig)
            let configDesc = OCIDescriptor.from(data: configData, mediaType: PhantomMediaType.vmConfig)
            let nvramDesc = OCIDescriptor.from(data: nvramData, mediaType: PhantomMediaType.nvram)

            var layers: [OCIDescriptor] = [configDesc, nvramDesc]
            for chunk in chunkMetadata {
                let desc = OCIDescriptor(
                    mediaType: PhantomMediaType.disk,
                    digest: chunk.digest,
                    size: chunk.compressedSize,
                    annotations: [
                        PhantomAnnotation.uncompressedSize: String(chunk.uncompressedSize)
                    ]
                )
                layers.append(desc)
            }

            let manifest = OCIManifest(config: ociConfigDesc, layers: layers)
            let manifestData = try manifest.toJSON()
            try manifestData.write(to: imageDir.appendingPathComponent("manifest.json"))
            try ociConfigData.write(to: imageDir.appendingPathComponent("oci-config.json"))

            log("Image '\(name)' saved successfully (\(chunkMetadata.count) disk chunks)")
            state = .completed(message: "Image '\(name)' saved")

        } catch {
            log("Failed to save image: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            try? FileManager.default.removeItem(at: imageDir)
        }
    }

    // MARK: - List Images

    func list() -> [ImageInfo] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: imagesDir, includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return entries.compactMap { entry -> ImageInfo? in
            let manifestPath = entry.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestPath.path) else { return nil }

            // Count disk chunks
            let diskDir = entry.appendingPathComponent("disk")
            let diskFiles = (try? FileManager.default.contentsOfDirectory(
                at: diskDir, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let lz4Files = diskFiles.filter { $0.pathExtension == "lz4" }

            // Calculate total size
            var totalSize: Int64 = 0
            for file in diskFiles {
                if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attrs.fileSize {
                    totalSize += Int64(size)
                }
            }
            // Add config and nvram sizes
            for name in ["config.json", "nvram.bin", "manifest.json"] {
                let path = entry.appendingPathComponent(name)
                if let attrs = try? path.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attrs.fileSize {
                    totalSize += Int64(size)
                }
            }

            // Get creation date
            let createdAt: String
            if let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path),
               let date = attrs[.creationDate] as? Date {
                let formatter = ISO8601DateFormatter()
                createdAt = formatter.string(from: date)
            } else {
                createdAt = "unknown"
            }

            return ImageInfo(
                name: entry.lastPathComponent,
                diskChunks: lz4Files.count,
                totalSize: totalSize,
                createdAt: createdAt
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Delete Image

    func delete(name: String) throws {
        let imageDir = imagesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: imageDir.path) else {
            throw OCIError.imageNotFound(name)
        }
        try FileManager.default.removeItem(at: imageDir)
        log("Deleted image '\(name)'")
    }

    // MARK: - Create VM from Image

    /// Create a new VM bundle from a local OCI image.
    /// - Parameters:
    ///   - name: Image name
    ///   - vmsDir: Directory where VM bundles are stored
    /// - Returns: The new VM ID
    func createVM(fromImage name: String, vmsDir: URL) async throws -> (vmId: String, bundlePath: URL) {
        let imageDir = imagesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: imageDir.path) else {
            throw OCIError.imageNotFound(name)
        }

        state = .saving(progress: 0, message: "Creating VM from image...")

        let updateProgress: @Sendable (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor [weak self] in
                self?.state = .saving(progress: progress, message: message)
            }
        }

        let vmId = "vm-\(UUID().uuidString.prefix(8).lowercased())"
        let bundlePath = vmsDir.appendingPathComponent(vmId, isDirectory: true)

        do {
            let bgLog: @Sendable (String) -> Void = { [weak self] msg in
                Task { @MainActor [weak self] in self?.log(msg) }
            }
            try await Task.detached {
                // Read VM config
                let configPath = imageDir.appendingPathComponent("config.json")
                let configData = try Data(contentsOf: configPath)
                let vmConfig = try PhantomVMConfig.fromJSON(configData)

                try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)

                // Write HardwareModel
                updateProgress(0.05, "Writing hardware model...")
                let hwData = try vmConfig.hardwareModelData()
                try hwData.write(to: bundlePath.appendingPathComponent("HardwareModel"))

                // Copy NVRAM
                updateProgress(0.1, "Copying NVRAM...")
                let nvramSrc = imageDir.appendingPathComponent("nvram.bin")
                try FileManager.default.copyItem(at: nvramSrc, to: bundlePath.appendingPathComponent("AuxiliaryStorage"))

                // Generate new MachineIdentifier
                let machineIdentifier = VZMacMachineIdentifier()
                try machineIdentifier.dataRepresentation.write(to: bundlePath.appendingPathComponent("MachineIdentifier"))

                // Reconstruct disk from chunks (one at a time to avoid memory spike)
                updateProgress(0.15, "Reconstructing disk...")
                let diskDir = imageDir.appendingPathComponent("disk")
                let chunkFiles = try FileManager.default.contentsOfDirectory(
                    at: diskDir, includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "lz4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

                let diskPath = bundlePath.appendingPathComponent("disk.img")
                FileManager.default.createFile(atPath: diskPath.path, contents: nil)
                let fileHandle = try FileHandle(forWritingTo: diskPath)
                defer { try? fileHandle.close() }
                try fileHandle.truncate(atOffset: vmConfig.diskSize)

                for (i, chunkFile) in chunkFiles.enumerated() {
                    try autoreleasepool {
                        let compressedData = try Data(contentsOf: chunkFile)
                        let decompressed = try OCIDiskLayerizer.decompress(compressedData, expectedSize: OCIDiskLayerizer.chunkSize)

                        if !OCIDiskLayerizer.isAllZeros(decompressed) {
                            let offset = UInt64(i) * UInt64(OCIDiskLayerizer.chunkSize)
                            try fileHandle.seek(toOffset: offset)
                            fileHandle.write(decompressed)
                        }
                    }
                    let progress = 0.15 + Double(i + 1) / Double(chunkFiles.count) * 0.8
                    updateProgress(progress, "Restoring disk \(Int(progress * 100))%")
                }

                bgLog("Created VM '\(vmId)' from image '\(name)'")
            }.value

            state = .completed(message: "VM '\(vmId)' created from image '\(name)'")
            return (vmId: vmId, bundlePath: bundlePath)

        } catch {
            try? FileManager.default.removeItem(at: bundlePath)
            throw error
        }
    }

    // MARK: - Push Image to Registry

    func push(name: String, reference: String, username: String?, password: String?) async {
        guard state == .idle || isTerminalState else {
            state = .error("An operation is already in progress")
            return
        }

        state = .pushing(progress: 0, message: "Preparing push...")
        log("Pushing image '\(name)' to \(reference)...")

        let updateProgress: @Sendable (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor [weak self] in
                self?.state = .pushing(progress: progress, message: message)
            }
        }

        do {
            let imageDir = imagesDir.appendingPathComponent(name)
            let bgLog: @Sendable (String) -> Void = { [weak self] msg in
                Task { @MainActor [weak self] in self?.log(msg) }
            }

            try await Task.detached {
                guard FileManager.default.fileExists(atPath: imageDir.path) else {
                    throw OCIError.imageNotFound(name)
                }

                let ref = try OCIReference(parsing: reference)
                let creds = RegistryCredentials.load(for: ref.registry, username: username, password: password)
                let client = OCIRegistryClient(reference: ref, credentials: creds)

                // Read manifest
                let manifestPath = imageDir.appendingPathComponent("manifest.json")
                let manifestData = try Data(contentsOf: manifestPath)
                let manifest = try OCIManifest.fromJSON(manifestData)

                // Push OCI config blob
                updateProgress(0.05, "Pushing config...")
                let ociConfigPath = imageDir.appendingPathComponent("oci-config.json")
                let ociConfigData = try Data(contentsOf: ociConfigPath)
                let ociConfigDigest = manifest.config.digest
                if !(try await client.blobExists(digest: ociConfigDigest)) {
                    try await client.pushBlob(data: ociConfigData, digest: ociConfigDigest)
                }

                // Push VM config layer
                let configPath = imageDir.appendingPathComponent("config.json")
                let configData = try Data(contentsOf: configPath)
                let configLayer = manifest.layers.first { $0.mediaType == PhantomMediaType.vmConfig }!
                if !(try await client.blobExists(digest: configLayer.digest)) {
                    try await client.pushBlob(data: configData, digest: configLayer.digest)
                }

                // Push NVRAM layer
                updateProgress(0.1, "Pushing NVRAM...")
                let nvramPath = imageDir.appendingPathComponent("nvram.bin")
                let nvramData = try Data(contentsOf: nvramPath)
                let nvramLayer = manifest.layers.first { $0.mediaType == PhantomMediaType.nvram }!
                if !(try await client.blobExists(digest: nvramLayer.digest)) {
                    try await client.pushBlob(data: nvramData, digest: nvramLayer.digest)
                }

                // Push disk chunk layers
                let diskLayers = manifest.layers.filter { $0.mediaType == PhantomMediaType.disk }
                let diskDir = imageDir.appendingPathComponent("disk")
                let chunkFiles = try FileManager.default.contentsOfDirectory(
                    at: diskDir, includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "lz4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

                for (i, chunkFile) in chunkFiles.enumerated() {
                    let progress = 0.1 + Double(i) / Double(chunkFiles.count) * 0.8
                    updateProgress(progress, "Pushing chunk \(i + 1)/\(chunkFiles.count)...")

                    let chunkData = try Data(contentsOf: chunkFile)
                    let layer = diskLayers[i]

                    if !(try await client.blobExists(digest: layer.digest)) {
                        try await client.pushBlob(data: chunkData, digest: layer.digest)
                        bgLog("Pushed chunk \(i + 1)/\(chunkFiles.count)")
                    } else {
                        bgLog("Chunk \(i + 1)/\(chunkFiles.count) already exists")
                    }
                }

                // Push manifest
                updateProgress(0.95, "Pushing manifest...")
                try await client.pushManifest(manifest, reference: ref.reference)

                bgLog("Image '\(name)' pushed to \(reference)")
            }.value

            state = .completed(message: "Image '\(name)' pushed to \(reference)")

        } catch {
            log("Push failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Pull Image from Registry

    func pull(reference: String, name: String?, username: String?, password: String?) async {
        guard state == .idle || isTerminalState else {
            state = .error("An operation is already in progress")
            return
        }

        state = .pulling(progress: 0, message: "Preparing pull...")
        log("Pulling image from \(reference)...")

        let updateProgress: @Sendable (Double, String) -> Void = { [weak self] progress, message in
            Task { @MainActor [weak self] in
                self?.state = .pulling(progress: progress, message: message)
            }
        }

        let imagesDir = self.imagesDir
        let bgLog: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor [weak self] in self?.log(msg) }
        }

        do {
            let imageName = try await Task.detached { () -> String in
                let ref = try OCIReference(parsing: reference)
                let creds = RegistryCredentials.load(for: ref.registry, username: username, password: password)
                let client = OCIRegistryClient(reference: ref, credentials: creds)

                let imageName = name ?? ref.namespace.split(separator: "/").last.map(String.init) ?? "pulled-image"
                let imageDir = imagesDir.appendingPathComponent(imageName)

                if FileManager.default.fileExists(atPath: imageDir.path) {
                    throw OCIError.imageAlreadyExists(imageName)
                }

                try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
                let diskDir = imageDir.appendingPathComponent("disk")
                try FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)

                // Pull manifest
                updateProgress(0.05, "Pulling manifest...")
                let manifest = try await client.pullManifest(reference: ref.reference)
                let manifestData = try manifest.toJSON()
                try manifestData.write(to: imageDir.appendingPathComponent("manifest.json"))

                // Pull OCI config
                let ociConfigData = try await client.pullBlob(digest: manifest.config.digest)
                try ociConfigData.write(to: imageDir.appendingPathComponent("oci-config.json"))

                // Pull VM config layer
                updateProgress(0.1, "Pulling config...")
                guard let configLayer = manifest.layers.first(where: { $0.mediaType == PhantomMediaType.vmConfig }) else {
                    throw OCIError.invalidManifest("Missing VM config layer")
                }
                let configData = try await client.pullBlob(digest: configLayer.digest)
                try configData.write(to: imageDir.appendingPathComponent("config.json"))

                // Pull NVRAM layer
                updateProgress(0.15, "Pulling NVRAM...")
                guard let nvramLayer = manifest.layers.first(where: { $0.mediaType == PhantomMediaType.nvram }) else {
                    throw OCIError.invalidManifest("Missing NVRAM layer")
                }
                let nvramData = try await client.pullBlob(digest: nvramLayer.digest)
                try nvramData.write(to: imageDir.appendingPathComponent("nvram.bin"))

                // Pull disk chunk layers
                let diskLayers = manifest.layers.filter { $0.mediaType == PhantomMediaType.disk }

                for (i, layer) in diskLayers.enumerated() {
                    let progress = 0.15 + Double(i) / Double(diskLayers.count) * 0.8
                    updateProgress(progress, "Pulling chunk \(i + 1)/\(diskLayers.count)...")

                    let chunkData = try await client.pullBlob(digest: layer.digest)
                    let chunkPath = diskDir.appendingPathComponent(String(format: "%03d.lz4", i))
                    try chunkData.write(to: chunkPath)

                    bgLog("Pulled chunk \(i + 1)/\(diskLayers.count)")
                }

                bgLog("Image '\(imageName)' pulled from \(reference)")
                return imageName
            }.value

            state = .completed(message: "Image '\(imageName)' pulled from \(reference)")

        } catch {
            log("Pull failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            if let name = name {
                let imageDir = imagesDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: imageDir)
            }
        }
    }

    // MARK: - Image Directory Access

    func imageDirectory(for name: String) -> URL {
        imagesDir.appendingPathComponent(name)
    }

    func imageExists(_ name: String) -> Bool {
        let manifestPath = imagesDir.appendingPathComponent(name).appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifestPath.path)
    }

    // MARK: - Helpers

    private var isTerminalState: Bool {
        switch state {
        case .completed, .error, .idle: return true
        default: return false
        }
    }
}
