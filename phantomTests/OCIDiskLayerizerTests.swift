import Foundation
import Testing
@testable import Phantom

struct OCIDiskLayerizerTests {

    // MARK: - Compression Round Trip

    @Test func compressDecompressRoundTrip() throws {
        let original = Data(repeating: 0xAB, count: 1024)
        let compressed = try OCIDiskLayerizer.compress(original)
        let decompressed = try OCIDiskLayerizer.decompress(compressed, expectedSize: original.count)
        #expect(decompressed == original)
    }

    @Test func compressDecompressRandomData() throws {
        var original = Data(count: 4096)
        for i in 0..<original.count {
            original[i] = UInt8(i % 256)
        }
        let compressed = try OCIDiskLayerizer.compress(original)
        let decompressed = try OCIDiskLayerizer.decompress(compressed, expectedSize: original.count)
        #expect(decompressed == original)
    }

    @Test func compressZeroDataCompressesWell() throws {
        let zeros = Data(count: 1024 * 1024) // 1MB of zeros
        let compressed = try OCIDiskLayerizer.compress(zeros)
        // Zeros should compress very well
        #expect(compressed.count < zeros.count / 10)
        let decompressed = try OCIDiskLayerizer.decompress(compressed, expectedSize: zeros.count)
        #expect(decompressed == zeros)
    }

    @Test func compressSmallData() throws {
        let small = Data([0x01, 0x02, 0x03])
        let compressed = try OCIDiskLayerizer.compress(small)
        let decompressed = try OCIDiskLayerizer.decompress(compressed, expectedSize: small.count)
        #expect(decompressed == small)
    }

    // MARK: - Zero Detection

    @Test func allZerosDetected() {
        let zeros = Data(count: 4096)
        #expect(OCIDiskLayerizer.isAllZeros(zeros) == true)
    }

    @Test func nonZerosDetected() {
        var data = Data(count: 4096)
        data[2048] = 1
        #expect(OCIDiskLayerizer.isAllZeros(data) == false)
    }

    @Test func emptyDataIsAllZeros() {
        #expect(OCIDiskLayerizer.isAllZeros(Data()) == true)
    }

    @Test func singleByteZero() {
        #expect(OCIDiskLayerizer.isAllZeros(Data([0x00])) == true)
    }

    @Test func singleByteNonZero() {
        #expect(OCIDiskLayerizer.isAllZeros(Data([0x01])) == false)
    }

    @Test func lastByteNonZero() {
        // Test the remainder path: 9 bytes = 1 UInt64 + 1 byte remainder
        var data = Data(count: 9)
        data[8] = 0xFF
        #expect(OCIDiskLayerizer.isAllZeros(data) == false)
    }

    // MARK: - Chunk and Reconstruct

    @Test func chunkAndReconstructSmallDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a small "disk" (2MB with some data)
        let diskPath = tempDir.appendingPathComponent("test-disk.img")
        let diskSize = 2 * 1024 * 1024 // 2MB
        var diskData = Data(count: diskSize)
        // Write a pattern in the first 1KB
        for i in 0..<1024 {
            diskData[i] = UInt8(i % 256)
        }
        try diskData.write(to: diskPath)

        // Create output dir for chunks
        let chunkDir = tempDir.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)

        // Chunk the disk
        var chunkProgress: [Double] = []
        let chunkMetadata = try await OCIDiskLayerizer.chunkDisk(at: diskPath, outputDir: chunkDir, progress: { p in
            chunkProgress.append(p)
        })

        #expect(chunkMetadata.count == 1) // 2MB < 512MB = 1 chunk
        #expect(chunkProgress.last == 1.0)
        #expect(chunkMetadata[0].offset == 0)
        #expect(chunkMetadata[0].uncompressedSize == diskSize)

        // Verify chunk file was written
        let chunkFile = chunkDir.appendingPathComponent("000.lz4")
        #expect(FileManager.default.fileExists(atPath: chunkFile.path))

        // Reconstruct
        let reconstructedPath = tempDir.appendingPathComponent("reconstructed.img")
        var reconstructProgress: [Double] = []
        let compressedData = try Data(contentsOf: chunkFile)
        try OCIDiskLayerizer.reconstructDisk(
            at: reconstructedPath,
            diskSize: UInt64(diskSize),
            chunks: [(offset: chunkMetadata[0].offset, compressedData: compressedData)],
            progress: { p in reconstructProgress.append(p) }
        )

        #expect(reconstructProgress.last == 1.0)

        // Verify content matches
        let reconstructedData = try Data(contentsOf: reconstructedPath)
        #expect(reconstructedData == diskData)
    }

    @Test func chunkEmptyDiskReturnsNoChunks() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskPath = tempDir.appendingPathComponent("empty.img")
        let chunkDir = tempDir.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: diskPath.path, contents: Data())

        let chunks = try await OCIDiskLayerizer.chunkDisk(at: diskPath, outputDir: chunkDir, progress: { _ in })
        #expect(chunks.count == 0)
    }

    @Test func allZeroDiskStoresNoChunks() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a disk that's all zeros
        let diskPath = tempDir.appendingPathComponent("zero.img")
        let diskSize: UInt64 = 4 * 1024 * 1024 // 4MB
        let zeroData = Data(count: Int(diskSize))
        try zeroData.write(to: diskPath)

        // Chunk it
        let chunkDir = tempDir.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        let chunkMetadata = try await OCIDiskLayerizer.chunkDisk(at: diskPath, outputDir: chunkDir, progress: { _ in })

        // Nothing to store: ftruncate alone reproduces an untouched disk.
        #expect(chunkMetadata.isEmpty)
        let written = try FileManager.default.contentsOfDirectory(atPath: chunkDir.path)
        #expect(written.isEmpty)

        // And it still restores, to a sparse file of the right length.
        let reconstructedPath = tempDir.appendingPathComponent("reconstructed.img")
        try OCIDiskLayerizer.reconstructDisk(
            at: reconstructedPath,
            diskSize: diskSize,
            chunks: [],
            progress: { _ in }
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: reconstructedPath.path)
        #expect(attrs[.size] as! UInt64 == diskSize)
        #expect(try Data(contentsOf: reconstructedPath) == zeroData)
    }

    /// A chunk's offset must come from its index, not from where it sits in the
    /// list — the invariant that lets all-zero chunks be dropped. Uses two small
    /// payloads at distant offsets so the disk stays a cheap sparse file rather
    /// than gigabytes of memory.
    @Test func reconstructWritesEachChunkAtItsOwnOffset() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunkSize = UInt64(OCIDiskLayerizer.chunkSize)
        let first = Data((0..<4096).map { UInt8($0 % 251) })
        let third = Data((0..<4096).map { UInt8(($0 * 7) % 253) })

        // Slots 0 and 2 are present, slot 1 is a hole.
        let path = tempDir.appendingPathComponent("holey.img")
        try OCIDiskLayerizer.reconstructDisk(
            at: path,
            diskSize: chunkSize * 3,
            chunks: [
                (offset: 0, compressedData: try OCIDiskLayerizer.compress(first)),
                (offset: chunkSize * 2, compressedData: try OCIDiskLayerizer.compress(third))
            ],
            progress: { _ in }
        )

        #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.size] as! UInt64 == chunkSize * 3)

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        #expect(try handle.read(upToCount: first.count) == first)

        // The hole reads back as zeros...
        try handle.seek(toOffset: chunkSize)
        #expect(try handle.read(upToCount: 4096) == Data(count: 4096))

        // ...and the second chunk landed at its own offset, not at chunkSize.
        try handle.seek(toOffset: chunkSize * 2)
        #expect(try handle.read(upToCount: third.count) == third)
    }

    @Test func chunkFileNamesRoundTripToIndices() {
        #expect(OCIDiskLayerizer.chunkFileName(index: 7) == "007.lz4")
        #expect(OCIDiskLayerizer.chunkFileName(index: 1234) == "1234.lz4")
        #expect(OCIDiskLayerizer.chunkIndex(fromFileName: "007.lz4") == 7)
        #expect(OCIDiskLayerizer.chunkIndex(fromFileName: "1234.lz4") == 1234)
        #expect(OCIDiskLayerizer.chunkIndex(fromFileName: "manifest.json") == nil)
        #expect(OCIDiskLayerizer.chunkIndex(fromFileName: "nvram.bin") == nil)
    }

    @Test func digestsAreDeterministic() throws {
        let data = Data(repeating: 0xCC, count: 1024)
        let compressed1 = try OCIDiskLayerizer.compress(data)
        let compressed2 = try OCIDiskLayerizer.compress(data)
        #expect(Digest.sha256(compressed1) == Digest.sha256(compressed2))
    }
}
