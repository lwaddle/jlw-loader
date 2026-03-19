import Foundation
import Compression

// MARK: - ZIPExtractor

enum ZIPExtractor {

    // MARK: - Errors

    enum ExtractionError: LocalizedError {
        case invalidArchive
        case readFailed
        case decompressionFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive:
                return "The file is not a valid ZIP archive."
            case .readFailed:
                return "Failed to read the ZIP archive."
            case .decompressionFailed(let name):
                return "Failed to decompress entry: \(name)"
            case .writeFailed(let name):
                return "Failed to write entry: \(name)"
            }
        }
    }

    // MARK: - ZIPEntry

    struct ZIPEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let dataOffset: Int

        var isDirectory: Bool {
            name.hasSuffix("/")
        }
    }

    // MARK: - Public API

    /// Extracts a ZIP archive to the destination directory.
    /// Returns the number of files extracted (excludes directories).
    static func extract(
        zipAt source: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ExtractionError.readFailed
        }

        guard data.count >= 4 else {
            throw ExtractionError.invalidArchive
        }

        let entries = try parseEntries(from: data)

        // Create destination if it doesn't exist
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        // Filter out __MACOSX/ resource fork entries and directories
        let fileEntries = entries.filter { !$0.name.hasPrefix("__MACOSX/") && !$0.isDirectory }
        let total = fileEntries.count

        var extracted = 0
        for entry in fileEntries {
            let outputURL = destination.appendingPathComponent(entry.name)

            // Create parent directories as needed
            let parentDir = outputURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            let fileData: Data
            switch entry.compressionMethod {
            case 0:
                // Stored — copy bytes directly
                let start = entry.dataOffset
                let end = start + Int(entry.compressedSize)
                guard end <= data.count else {
                    throw ExtractionError.decompressionFailed(entry.name)
                }
                fileData = data[start..<end]

            case 8:
                // Deflated — decompress with COMPRESSION_ZLIB
                let start = entry.dataOffset
                let end = start + Int(entry.compressedSize)
                guard end <= data.count else {
                    throw ExtractionError.decompressionFailed(entry.name)
                }
                let compressedData = data[start..<end]
                fileData = try decompressDeflate(
                    compressedData,
                    uncompressedSize: Int(entry.uncompressedSize),
                    name: entry.name
                )

            default:
                throw ExtractionError.decompressionFailed(entry.name)
            }

            do {
                try fileData.write(to: outputURL)
            } catch {
                throw ExtractionError.writeFailed(entry.name)
            }

            extracted += 1
            onProgress(extracted, total)
        }

        return extracted
    }

    // MARK: - Private Helpers

    /// Parses local file headers from ZIP data.
    private static func parseEntries(from data: Data) throws -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var offset = 0
        let localHeaderSignature: UInt32 = 0x04034B50 // PK\x03\x04

        while offset + 30 <= data.count {
            let sig = readUInt32(from: data, at: offset)
            guard sig == localHeaderSignature else {
                break
            }

            let generalFlag = readUInt16(from: data, at: offset + 6)
            let compressionMethod = readUInt16(from: data, at: offset + 8)
            let compressedSize = readUInt32(from: data, at: offset + 18)
            let uncompressedSize = readUInt32(from: data, at: offset + 22)
            let fileNameLength = Int(readUInt16(from: data, at: offset + 26))
            let extraFieldLength = Int(readUInt16(from: data, at: offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else {
                throw ExtractionError.invalidArchive
            }

            guard let fileName = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw ExtractionError.invalidArchive
            }

            let dataOffset = nameEnd + extraFieldLength

            let entry = ZIPEntry(
                name: fileName,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                dataOffset: dataOffset
            )
            entries.append(entry)

            offset = dataOffset + Int(compressedSize)

            // Skip optional data descriptor (if bit 3 of general purpose flag is set)
            if generalFlag & 0x08 != 0 {
                // Data descriptor may or may not have signature
                if offset + 4 <= data.count && readUInt32(from: data, at: offset) == 0x08074B50 {
                    offset += 16 // signature(4) + crc(4) + compressed(4) + uncompressed(4)
                } else if offset + 12 <= data.count {
                    offset += 12 // crc(4) + compressed(4) + uncompressed(4)
                }
            }
        }

        if entries.isEmpty {
            throw ExtractionError.invalidArchive
        }

        return entries
    }

    /// Decompresses deflated data using the Compression framework.
    private static func decompressDeflate(
        _ compressed: Data,
        uncompressedSize: Int,
        name: String
    ) throws -> Data {
        // Use raw DEFLATE via compression_decode_buffer with COMPRESSION_ZLIB
        let destinationSize = max(uncompressedSize, 1)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }

        let decodedSize = compressed.withUnsafeBytes { rawBuffer -> Int in
            guard let sourcePointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_decode_buffer(
                destinationBuffer,
                destinationSize,
                sourcePointer,
                compressed.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decodedSize > 0 || uncompressedSize == 0 else {
            throw ExtractionError.decompressionFailed(name)
        }

        return Data(bytes: destinationBuffer, count: decodedSize)
    }

    /// Reads a little-endian UInt16 from data at the given offset.
    static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt16.self)
        }
    }

    /// Reads a little-endian UInt32 from data at the given offset.
    static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt32.self)
        }
    }
}
