import Compression
import Foundation

// MARK: - Disk Layerizer

/// Handles splitting VM disk images into LZ4-compressed chunks and reassembling them.
enum OCIDiskLayerizer {
    /// 512 MB chunk size
    static let chunkSize = 512 * 1024 * 1024

    /// Metadata for a compressed disk chunk (without holding the data in memory)
    struct ChunkMetadata {
        let index: Int
        let offset: UInt64
        let compressedSize: Int64
        let uncompressedSize: Int
        let digest: String
    }

    // MARK: - Chunking (for save/push)

    /// Split a disk image into LZ4-compressed chunks, writing each to disk immediately.
    /// - Parameters:
    ///   - path: Path to the disk image file
    ///   - outputDir: Directory to write compressed .lz4 files into
    ///   - progress: Callback with fraction complete (0.0...1.0)
    /// - Returns: Array of chunk metadata (data written to outputDir, not held in memory)
    static func chunkDisk(at path: URL, outputDir: URL, progress: @escaping (Double) -> Void) throws -> [ChunkMetadata] {
        let fileHandle = try FileHandle(forReadingFrom: path)
        defer { try? fileHandle.close() }

        let fileSize = try fileHandle.seekToEnd()
        try fileHandle.seek(toOffset: 0)

        guard fileSize > 0 else {
            return []
        }

        let totalChunks = Int((fileSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        var metadata: [ChunkMetadata] = []
        metadata.reserveCapacity(totalChunks)

        for i in 0..<totalChunks {
            // autoreleasepool ensures NSData-backed buffers from FileHandle.read
            // are released after each chunk, preventing all chunks from accumulating
            // in the autorelease pool simultaneously (which would reach 64GB+ for a full disk).
            let chunkMeta: ChunkMetadata = try autoreleasepool {
                let offset = UInt64(i) * UInt64(chunkSize)
                try fileHandle.seek(toOffset: offset)

                guard let rawData = try fileHandle.read(upToCount: chunkSize), !rawData.isEmpty else {
                    throw OCIError.compressionFailed("Unexpected empty read at chunk \(i)")
                }

                let compressed = try compress(rawData)
                let digest = Digest.sha256(compressed)

                let chunkPath = outputDir.appendingPathComponent(String(format: "%03d.lz4", i))
                try compressed.write(to: chunkPath)

                return ChunkMetadata(
                    index: i,
                    offset: offset,
                    compressedSize: Int64(compressed.count),
                    uncompressedSize: rawData.count,
                    digest: digest
                )
            }
            metadata.append(chunkMeta)
            progress(Double(i + 1) / Double(totalChunks))
        }

        return metadata
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
