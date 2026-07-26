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
    ///   - replace: Overwrite an image of the same name instead of failing.
    ///     Rebuilding an image in place is the normal way to refresh one (its
    ///     name is what jobs and `image publish` refer to), and there is no
    ///     rename — so the new copy is written beside the old one and swapped
    ///     in only once it is complete. A failed save leaves the old image
    ///     untouched, at the cost of needing room for both while it runs.
    func save(name: String, bundlePath: URL, replace: Bool = false) async {
        guard state == .idle || isTerminalState else {
            state = .error("An operation is already in progress")
            return
        }

        state = .saving(progress: 0, message: "Preparing...")
        log("Saving VM to image '\(name)'...")

        let finalDir = imagesDir.appendingPathComponent(name)
        let replacing = replace && FileManager.default.fileExists(atPath: finalDir.path)
        let imageDir = replacing
            ? imagesDir.appendingPathComponent(".\(name).saving-\(UUID().uuidString)")
            : finalDir
        let diskDir = imageDir.appendingPathComponent("disk")
        if replacing { log("Image '\(name)' exists — building a replacement alongside it") }

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

                // Read MachineIdentifier — the ECID this VM ran Setup Assistant
                // under, kept so restores present the same machine to the guest.
                let idPath = bundlePath.appendingPathComponent("MachineIdentifier")
                let idData = try Data(contentsOf: idPath)

                // Get disk size
                let diskPath = bundlePath.appendingPathComponent("disk.img")
                let diskAttrs = try FileManager.default.attributesOfItem(atPath: diskPath.path)
                let diskSize = diskAttrs[.size] as? UInt64 ?? 0

                // Write VM config (with HardwareModel and MachineIdentifier embedded)
                let vmConfig = PhantomVMConfig(
                    hardwareModel: hwData,
                    diskSize: diskSize,
                    machineIdentifier: idData
                )
                let configData = try vmConfig.toJSON()
                let configPath = imageDir.appendingPathComponent("config.json")
                try configData.write(to: configPath)

                // Copy NVRAM
                let auxPath = bundlePath.appendingPathComponent("AuxiliaryStorage")
                let nvramPath = imageDir.appendingPathComponent("nvram.bin")
                try FileManager.default.copyItem(at: auxPath, to: nvramPath)

                // Chunk disk image (writes each chunk to disk immediately)
                bgLog("Chunking disk image...")
                let metadata = try await OCIDiskLayerizer.chunkDisk(at: diskPath, outputDir: diskDir) { progress in
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
                        PhantomAnnotation.uncompressedSize: String(chunk.uncompressedSize),
                        PhantomAnnotation.chunkIndex: String(chunk.index)
                    ]
                )
                layers.append(desc)
            }

            let manifest = OCIManifest(config: ociConfigDesc, layers: layers)
            let manifestData = try manifest.toJSON()
            try manifestData.write(to: imageDir.appendingPathComponent("manifest.json"))
            try ociConfigData.write(to: imageDir.appendingPathComponent("oci-config.json"))

            // The replacement is complete — swap it in. The old image (and its
            // pulled.json, which no longer describes these bytes) goes away.
            if replacing {
                try? FileManager.default.removeItem(at: finalDir)
                try FileManager.default.moveItem(at: imageDir, to: finalDir)
            }

            log("Image '\(name)' saved successfully (\(chunkMetadata.count) disk chunks, all-zero chunks omitted)")
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

            // Absent for locally saved images, and for anything pulled before
            // pull started recording it.
            let pullRecordPath = entry.appendingPathComponent("pulled.json")
            let pulledFrom = (try? Data(contentsOf: pullRecordPath)).flatMap {
                try? JSONDecoder().decode(PullRecord.self, from: $0)
            }

            return ImageInfo(
                name: entry.lastPathComponent,
                diskChunks: lz4Files.count,
                totalSize: totalSize,
                createdAt: createdAt,
                pulledFrom: pulledFrom
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

    // MARK: - Restore a VM Bundle from an Image

    /// Write a local OCI image out as a VM bundle at `bundlePath`.
    ///
    /// Progress (0…1) is reported through `progress` rather than `state`: the
    /// caller owns a VM, and `state` is a single slot shared by save/push/pull,
    /// so parking restore progress there would have a restore and a concurrent
    /// pull scribble over each other. Cleans up the half-written bundle if it
    /// fails, and leaves nothing behind that `loadExistingVMs` would adopt.
    func restore(
        image name: String,
        into bundlePath: URL,
        progress updateProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let imageDir = imagesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: imageDir.path) else {
            throw OCIError.imageNotFound(name)
        }

        let vmId = bundlePath.lastPathComponent

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
                updateProgress(0.05)
                let hwData = try vmConfig.hardwareModelData()
                try hwData.write(to: bundlePath.appendingPathComponent("HardwareModel"))

                // Copy NVRAM
                updateProgress(0.1)
                let nvramSrc = imageDir.appendingPathComponent("nvram.bin")
                try FileManager.default.copyItem(at: nvramSrc, to: bundlePath.appendingPathComponent("AuxiliaryStorage"))

                // Reconstruct disk from chunks in parallel using pwrite
                // pwrite allows concurrent writes at different offsets without seeking
                updateProgress(0.15)
                let diskDir = imageDir.appendingPathComponent("disk")
                // Each file's name carries its chunk index; all-zero chunks were
                // never stored, so position in the directory means nothing.
                let chunkFiles: [(index: Int, url: URL)] = try FileManager.default.contentsOfDirectory(
                    at: diskDir, includingPropertiesForKeys: nil
                ).compactMap { url in
                    guard let index = OCIDiskLayerizer.chunkIndex(fromFileName: url.lastPathComponent) else {
                        return nil
                    }
                    return (index, url)
                }.sorted { $0.index < $1.index }

                let diskPath = bundlePath.appendingPathComponent("disk.img")
                FileManager.default.createFile(atPath: diskPath.path, contents: nil)
                let diskFD = Darwin.open(diskPath.path, O_WRONLY)
                guard diskFD >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno), userInfo: nil)
                }
                defer { Darwin.close(diskFD) }
                guard Darwin.ftruncate(diskFD, off_t(vmConfig.diskSize)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno), userInfo: nil)
                }

                // Decompress chunks in parallel across cores; the cap bounds
                // peak RAM (maxConcurrency × 512 MB).
                let maxConcurrent = OCIDiskLayerizer.maxConcurrency
                let chunkCount = chunkFiles.count
                var inFlight = 0
                var completedCount = 0

                try await withThrowingTaskGroup(of: Int.self) { group in
                    for (i, chunk) in chunkFiles.enumerated() {
                        if inFlight >= maxConcurrent {
                            _ = try await group.next()
                            inFlight -= 1
                            completedCount += 1
                            updateProgress(0.15 + Double(completedCount) / Double(chunkCount) * 0.8)
                        }

                        let chunkFile = chunk.url
                        let offset = off_t(UInt64(chunk.index) * UInt64(OCIDiskLayerizer.chunkSize))
                        let fd = diskFD

                        group.addTask {
                            try autoreleasepool {
                                let compressedData = try Data(contentsOf: chunkFile)
                                let decompressed = try OCIDiskLayerizer.decompress(compressedData, expectedSize: OCIDiskLayerizer.chunkSize)

                                // Skip all-zero chunks to keep the disk sparse
                                if !OCIDiskLayerizer.isAllZeros(decompressed) {
                                    let written = decompressed.withUnsafeBytes { ptr in
                                        Darwin.pwrite(fd, ptr.baseAddress!, decompressed.count, offset)
                                    }
                                    guard written == decompressed.count else {
                                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno), userInfo: nil)
                                    }
                                }
                            }
                            return i
                        }
                        inFlight += 1
                    }

                    for try await _ in group {
                        completedCount += 1
                        updateProgress(0.15 + Double(completedCount) / Double(chunkCount) * 0.8)
                    }
                }

                // Written last, once the disk is whole: a bundle is only a VM
                // to `loadExistingVMs` when all four files are present, so a
                // daemon killed mid-restore leaves a directory that won't come
                // back as a VM with a half-decompressed disk.
                //
                // Reuse the identifier the image was saved with, so the guest
                // boots on the same machine it finished Setup Assistant on — a
                // fresh ECID reads as new hardware and sends macOS back through
                // the Software Update / Apple Account / FileVault panes. Images
                // saved before the field existed still get a generated one.
                let identifierData = try vmConfig.machineIdentifierData()
                    ?? VZMacMachineIdentifier().dataRepresentation
                try identifierData.write(to: bundlePath.appendingPathComponent("MachineIdentifier"))

                bgLog("Restored VM '\(vmId)' from image '\(name)'")
            }.value

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

                // Take the file name from each layer's own index rather than
                // pairing a directory listing with the manifest by position —
                // with all-zero chunks omitted, only the index is meaningful.
                for (i, layer) in diskLayers.enumerated() {
                    let progress = 0.1 + Double(i) / Double(diskLayers.count) * 0.8
                    updateProgress(progress, "Pushing chunk \(i + 1)/\(diskLayers.count)...")

                    let index = layer.chunkIndex ?? i
                    let chunkFile = diskDir.appendingPathComponent(
                        OCIDiskLayerizer.chunkFileName(index: index)
                    )
                    let chunkData = try Data(contentsOf: chunkFile)

                    if !(try await client.blobExists(digest: layer.digest)) {
                        try await client.pushBlob(data: chunkData, digest: layer.digest)
                        bgLog("Pushed chunk \(i + 1)/\(diskLayers.count)")
                    } else {
                        bgLog("Chunk \(i + 1)/\(diskLayers.count) already exists")
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

    /// - Parameter replace: delete an existing image of the same name first,
    ///   for updating to a newer published digest. The old copy goes before the
    ///   new one arrives — there is no second copy on disk, so a pull that fails
    ///   leaves the name empty and has to be retried.
    func pull(
        reference: String,
        name: String?,
        username: String?,
        password: String?,
        replace: Bool = false
    ) async {
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
                    guard replace else { throw OCIError.imageAlreadyExists(imageName) }
                    bgLog("Replacing existing image '\(imageName)'")
                    try FileManager.default.removeItem(at: imageDir)
                }

                try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
                let diskDir = imageDir.appendingPathComponent("disk")
                try FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)

                // Pull manifest
                updateProgress(0.05, "Pulling manifest...")
                let (manifest, manifestDigest) = try await client.pullManifest(reference: ref.reference)
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

                // Pull disk chunk layers.
                //
                // Concurrently, because a single connection to a registry CDN is
                // the bottleneck, not the link: pulling 138 chunks one at a time
                // measured ~9MB/s against ghcr while the same link pushed at
                // ~23MB/s. The cap is shared with restore, and bounds peak RAM
                // the same way — each in-flight chunk buffers up to 512MB.
                let diskLayers = manifest.layers.filter { $0.mediaType == PhantomMediaType.disk }
                let total = diskLayers.count
                var completed = 0

                try await withThrowingTaskGroup(of: Void.self) { group in
                    var next = 0
                    var inFlight = 0

                    func schedule(_ i: Int) {
                        let layer = diskLayers[i]
                        // Preserve the layer's own index in the file name —
                        // restore derives its write offset from it.
                        let chunkPath = diskDir.appendingPathComponent(
                            OCIDiskLayerizer.chunkFileName(index: layer.chunkIndex ?? i)
                        )
                        group.addTask {
                            let chunkData = try await client.pullBlob(digest: layer.digest)
                            try chunkData.write(to: chunkPath)
                        }
                        next += 1
                        inFlight += 1
                    }

                    while next < total && inFlight < OCIDiskLayerizer.maxConcurrency { schedule(next) }

                    while inFlight > 0 {
                        try await group.next()
                        inFlight -= 1
                        completed += 1
                        let progress = 0.15 + Double(completed) / Double(total) * 0.8
                        updateProgress(progress, "Pulling chunk \(completed)/\(total)...")
                        if next < total { schedule(next) }
                    }
                }

                bgLog("Pulled \(total) disk chunks")

                // Last, so a half-finished pull leaves no record claiming the
                // image is at this digest.
                let record = PullRecord(
                    reference: reference,
                    digest: manifestDigest,
                    pulledAt: ISO8601DateFormatter().string(from: Date())
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                try encoder.encode(record).write(to: imageDir.appendingPathComponent("pulled.json"))

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
