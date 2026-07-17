import Compression
import Foundation

// MARK: - Disk Layerizer

/// Handles splitting VM disk images into LZ4-compressed chunks and reassembling them.
///
/// `nonisolated` so its CPU-heavy compress/decompress work runs on whatever
/// background executor calls it, in true parallel. Without this the project's
/// default MainActor isolation would hop every chunk back to the main thread,
/// serializing the work no matter how many concurrent tasks the caller spawns.
nonisolated enum OCIDiskLayerizer {
    /// 512 MB chunk size
    static let chunkSize = 512 * 1024 * 1024

    /// Concurrency for chunk compress/decompress. Each in-flight chunk holds up
    /// to one 512 MB buffer, so this also bounds peak RAM (cap × 512 MB).
    static var maxConcurrency: Int {
        min(ProcessInfo.processInfo.activeProcessorCount, 6)
    }

    /// Metadata for a compressed disk chunk (without holding the data in memory)
    struct ChunkMetadata {
        let index: Int
        let offset: UInt64
        let compressedSize: Int64
        let uncompressedSize: Int
        let digest: String
    }

    // MARK: - Chunking (for save/push)

    /// Split a disk image into LZ4-compressed chunks, writing each to disk.
    /// Chunks are compressed concurrently across cores; each task reads its own
    /// range with `pread` (thread-safe, doesn't move the shared fd offset).
    /// - Parameters:
    ///   - path: Path to the disk image file
    ///   - outputDir: Directory to write compressed .lz4 files into
    ///   - progress: Callback with fraction complete (0.0...1.0)
    /// - Returns: Array of chunk metadata (data written to outputDir, not held in memory)
    static func chunkDisk(at path: URL, outputDir: URL, progress: @escaping (Double) -> Void) async throws -> [ChunkMetadata] {
        let fd = Darwin.open(path.path, O_RDONLY)
        guard fd >= 0 else {
            throw OCIError.compressionFailed("Failed to open disk image: \(path.path)")
        }
        defer { Darwin.close(fd) }

        let fileSize = UInt64(Darwin.lseek(fd, 0, SEEK_END))
        guard fileSize > 0 else { return [] }

        let totalChunks = Int((fileSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        var results = [ChunkMetadata?](repeating: nil, count: totalChunks)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, ChunkMetadata).self) { group in
            var next = 0
            var inFlight = 0

            func schedule(_ i: Int) {
                group.addTask {
                    (i, try compressChunk(fd: fd, index: i, fileSize: fileSize, outputDir: outputDir))
                }
                next += 1
                inFlight += 1
            }

            while next < totalChunks && inFlight < maxConcurrency { schedule(next) }

            while inFlight > 0 {
                let (index, meta) = try await group.next()!
                results[index] = meta
                inFlight -= 1
                completed += 1
                progress(Double(completed) / Double(totalChunks))
                if next < totalChunks { schedule(next) }
            }
        }

        return results.compactMap { $0 }
    }

    /// Reads one chunk with `pread`, LZ4-compresses it, and writes the `.lz4`.
    private static func compressChunk(fd: Int32, index: Int, fileSize: UInt64, outputDir: URL) throws -> ChunkMetadata {
        try autoreleasepool {
            let offset = UInt64(index) * UInt64(chunkSize)
            let thisSize = Int(min(UInt64(chunkSize), fileSize - offset))
            var raw = Data(count: thisSize)

            let readCount = raw.withUnsafeMutableBytes { ptr in
                Darwin.pread(fd, ptr.baseAddress, thisSize, off_t(offset))
            }
            guard readCount == thisSize else {
                throw OCIError.compressionFailed("Short read at chunk \(index): \(readCount) != \(thisSize)")
            }

            let compressed = try compress(raw)
            let digest = Digest.sha256(compressed)
            let chunkPath = outputDir.appendingPathComponent(String(format: "%03d.lz4", index))
            try compressed.write(to: chunkPath)

            return ChunkMetadata(
                index: index,
                offset: offset,
                compressedSize: Int64(compressed.count),
                uncompressedSize: thisSize,
                digest: digest
            )
        }
    }

    // MARK: - Reconstruction (for pull/restore)

    /// Reassemble a disk image from LZ4-compressed chunks.
    /// - Parameters:
    ///   - path: Destination path for the disk image
    ///   - diskSize: Total uncompressed disk size (for ftruncate)
    ///   - chunks: Ordered array of (offset, compressedData) tuples
    ///   - progress: Callback with fraction complete (0.0...1.0)
    static func reconstructDisk(
        at path: URL,
        diskSize: UInt64,
        chunks: [(offset: UInt64, compressedData: Data)],
        progress: @escaping (Double) -> Void
    ) throws {
        // Create sparse disk image
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: path)
        defer { try? fileHandle.close() }

        try fileHandle.truncate(atOffset: diskSize)

        let total = chunks.count
        for (i, chunk) in chunks.enumerated() {
            try autoreleasepool {
                let decompressed = try decompress(chunk.compressedData, expectedSize: chunkSize)

                // Skip writing all-zero chunks to preserve sparseness
                if !isAllZeros(decompressed) {
                    try fileHandle.seek(toOffset: chunk.offset)
                    fileHandle.write(decompressed)
                }
            }
            progress(Double(i + 1) / Double(total))
        }
    }

    // MARK: - Compression

    /// LZ4 compress data using Apple's Compression framework.
    static func compress(_ data: Data) throws -> Data {
        let sourceSize = data.count
        // Worst case: LZ4 can expand data slightly
        let destinationBufferSize = sourceSize + (sourceSize / 255) + 16
        var destinationBuffer = Data(count: destinationBufferSize)

        let compressedSize = data.withUnsafeBytes { sourceBuffer in
            destinationBuffer.withUnsafeMutableBytes { destBuffer in
                compression_encode_buffer(
                    destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationBufferSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    sourceSize,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        guard compressedSize > 0 else {
            throw OCIError.compressionFailed("LZ4 compression returned 0 bytes")
        }

        return destinationBuffer.prefix(compressedSize)
    }

    /// LZ4 decompress data using Apple's Compression framework.
    /// - Parameters:
    ///   - data: Compressed data
    ///   - expectedSize: Expected decompressed size (chunk size or last chunk size)
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        // Allow up to the full chunk size for decompression
        let destinationBufferSize = max(expectedSize, chunkSize)
        var destinationBuffer = Data(count: destinationBufferSize)

        let decompressedSize = data.withUnsafeBytes { sourceBuffer in
            destinationBuffer.withUnsafeMutableBytes { destBuffer in
                compression_decode_buffer(
                    destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationBufferSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        guard decompressedSize > 0 else {
            throw OCIError.decompressionFailed("LZ4 decompression returned 0 bytes")
        }

        return destinationBuffer.prefix(decompressedSize)
    }

    // MARK: - Zero Detection

    /// Check if data is entirely zeros. Used to skip writing zero chunks and preserve disk sparseness.
    static func isAllZeros(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            let ptr = baseAddress.assumingMemoryBound(to: UInt64.self)
            let count = data.count / MemoryLayout<UInt64>.size

            for i in 0..<count {
                if ptr[i] != 0 { return false }
            }

            // Check remaining bytes
            let remainder = data.count % MemoryLayout<UInt64>.size
            if remainder > 0 {
                let bytePtr = baseAddress.assumingMemoryBound(to: UInt8.self)
                for i in (data.count - remainder)..<data.count {
                    if bytePtr[i] != 0 { return false }
                }
            }

            return true
        }
    }
}
