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
                return "The update package is not a valid ZIP file."
            case .readFailed:
                return "Could not read the update package."
            case .decompressionFailed(let name):
                return "Failed to decompress file: \(name)"
            case .writeFailed(let name):
                return "Failed to write file: \(name)"
            }
        }
    }

    // MARK: - ZIPEntry

    private struct ZIPEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32

        var isDirectory: Bool {
            name.hasSuffix("/")
        }

        /// Compute where file data starts by reading the local file header at the stored offset.
        func dataOffset(in data: Data) -> Int {
            let offset = Int(localHeaderOffset)
            let fileNameLength = Int(readUInt16(from: data, at: offset + 26))
            let extraFieldLength = Int(readUInt16(from: data, at: offset + 28))
            return offset + 30 + fileNameLength + extraFieldLength
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

        guard data.count >= 22 else {
            throw ExtractionError.invalidArchive
        }

        // Parse entries from the central directory (always has correct sizes,
        // even when local headers use data descriptors with zeroed sizes).
        let entries = try parseCentralDirectory(from: data)

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

            // Guard against path traversal (e.g., "../../etc/something")
            let resolvedPath = outputURL.standardizedFileURL.path
            let destPath = destination.standardizedFileURL.path
            guard resolvedPath.hasPrefix(destPath) else {
                throw ExtractionError.invalidArchive
            }

            // Create parent directories as needed
            let parentDir = outputURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            let dataStart = entry.dataOffset(in: data)

            let fileData: Data
            switch entry.compressionMethod {
            case 0:
                // Stored — copy bytes directly
                let end = dataStart + Int(entry.compressedSize)
                guard end <= data.count else {
                    throw ExtractionError.decompressionFailed(entry.name)
                }
                fileData = data[dataStart..<end]

            case 8:
                // Deflated — decompress with COMPRESSION_ZLIB
                let end = dataStart + Int(entry.compressedSize)
                guard end <= data.count else {
                    throw ExtractionError.decompressionFailed(entry.name)
                }
                let compressedData = data[dataStart..<end]
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

            // Sync to physical media (critical for external USB drives)
            if let handle = try? FileHandle(forWritingTo: outputURL) {
                handle.synchronizeFile()
                handle.closeFile()
            }

            extracted += 1
            onProgress(extracted, total)
        }

        return extracted
    }

    // MARK: - Central Directory Parsing

    /// Parses the central directory to get entries with correct sizes.
    /// The central directory always has accurate compressedSize/uncompressedSize,
    /// unlike local file headers which may be zeroed when data descriptors are used.
    private static func parseCentralDirectory(from data: Data) throws -> [ZIPEntry] {
        // Find End of Central Directory record (scan backward for PK\x05\x06)
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65557) // max comment = 65535 + 22 byte EOCD
        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if data[i] == eocdSignature[0],
               data[i+1] == eocdSignature[1],
               data[i+2] == eocdSignature[2],
               data[i+3] == eocdSignature[3] {
                eocdOffset = i
                break
            }
        }

        guard eocdOffset >= 0 else {
            throw ExtractionError.invalidArchive
        }

        let entryCount = Int(readUInt16(from: data, at: eocdOffset + 10))
        let centralDirOffset = Int(readUInt32(from: data, at: eocdOffset + 16))

        guard centralDirOffset >= 0, centralDirOffset < data.count else {
            throw ExtractionError.invalidArchive
        }

        var entries: [ZIPEntry] = []
        var offset = centralDirOffset
        let centralDirSignature: UInt32 = 0x02014B50 // PK\x01\x02

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count else {
                throw ExtractionError.invalidArchive
            }

            let sig = readUInt32(from: data, at: offset)
            guard sig == centralDirSignature else {
                throw ExtractionError.invalidArchive
            }

            let compressionMethod = readUInt16(from: data, at: offset + 10)
            let compressedSize = readUInt32(from: data, at: offset + 20)
            let uncompressedSize = readUInt32(from: data, at: offset + 24)
            let fileNameLength = Int(readUInt16(from: data, at: offset + 28))
            let extraFieldLength = Int(readUInt16(from: data, at: offset + 30))
            let commentLength = Int(readUInt16(from: data, at: offset + 32))
            let localHeaderOffset = readUInt32(from: data, at: offset + 42)

            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else {
                throw ExtractionError.invalidArchive
            }

            guard let fileName = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw ExtractionError.invalidArchive
            }

            entries.append(ZIPEntry(
                name: fileName,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            offset = nameEnd + extraFieldLength + commentLength
        }

        if entries.isEmpty {
            throw ExtractionError.invalidArchive
        }

        return entries
    }

    // MARK: - Decompression

    /// Decompresses deflated data using the Compression framework.
    private static func decompressDeflate(
        _ compressed: Data,
        uncompressedSize: Int,
        name: String
    ) throws -> Data {
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

    // MARK: - Binary Helpers

    /// Reads a little-endian UInt16 from data at the given offset.
    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt16.self).littleEndian
        }
    }

    /// Reads a little-endian UInt32 from data at the given offset.
    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt32.self).littleEndian
        }
    }
}
