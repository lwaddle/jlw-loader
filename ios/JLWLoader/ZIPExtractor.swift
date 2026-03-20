import Foundation
import Compression

// MARK: - ZIPExtractor

enum ZIPExtractor {

    // MARK: - Errors

    enum ExtractionError: LocalizedError {
        case invalidArchive(String)
        case readFailed
        case decompressionFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let detail):
                return "The update package is not a valid ZIP file. (\(detail))"
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
            throw ExtractionError.invalidArchive("File too small: \(data.count) bytes")
        }

        // Verify this looks like a ZIP (starts with PK signature)
        guard data.count >= 4,
              data[data.startIndex] == 0x50,
              data[data.startIndex + 1] == 0x4B else {
            // Show first bytes for diagnostics
            let preview = data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            throw ExtractionError.invalidArchive("Not a ZIP file. First bytes: \(preview)")
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

        guard total > 0 else {
            throw ExtractionError.invalidArchive("ZIP contains no extractable files (\(entries.count) total entries, all filtered)")
        }

        var extracted = 0
        let destinationPath = destination.standardizedFileURL.path
        for entry in fileEntries {
            // Guard against path traversal
            guard !entry.name.contains("../"),
                  !entry.name.contains("..\\"),
                  !entry.name.hasPrefix("/"),
                  !entry.name.hasPrefix("\\") else {
                throw ExtractionError.invalidArchive("Path traversal in entry: \(entry.name)")
            }

            let outputURL = destination.appendingPathComponent(entry.name)

            // Verify resolved path stays within destination
            guard outputURL.standardizedFileURL.path.hasPrefix(destinationPath) else {
                throw ExtractionError.invalidArchive("Path traversal in entry: \(entry.name)")
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
                throw ExtractionError.decompressionFailed("\(entry.name) (unsupported method \(entry.compressionMethod))")
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
        var eocdOffset = -1
        let searchStart = max(data.startIndex, data.endIndex - 65557)
        for i in stride(from: data.endIndex - 22, through: searchStart, by: -1) {
            if data[i] == 0x50,
               data[i+1] == 0x4B,
               data[i+2] == 0x05,
               data[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }

        guard eocdOffset >= 0 else {
            throw ExtractionError.invalidArchive("No EOCD record found in last 65KB. File size: \(data.count)")
        }

        let entryCount = Int(readUInt16(from: data, at: eocdOffset + 10))
        let centralDirOffset = Int(readUInt32(from: data, at: eocdOffset + 16))

        guard centralDirOffset >= 0, centralDirOffset < data.count else {
            throw ExtractionError.invalidArchive(
                "Central directory offset \(centralDirOffset) out of range (file size: \(data.count))"
            )
        }

        var entries: [ZIPEntry] = []
        var offset = centralDirOffset

        for i in 0..<entryCount {
            guard offset + 46 <= data.count else {
                throw ExtractionError.invalidArchive(
                    "CD entry \(i)/\(entryCount) at offset \(offset) exceeds file size \(data.count)"
                )
            }

            let sig = readUInt32(from: data, at: offset)
            guard sig == 0x02014B50 else {
                throw ExtractionError.invalidArchive(
                    "CD entry \(i)/\(entryCount) bad signature 0x\(String(sig, radix: 16)) at offset \(offset)"
                )
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
                throw ExtractionError.invalidArchive(
                    "CD entry \(i) filename extends past EOF (offset \(nameStart), len \(fileNameLength))"
                )
            }

            guard let fileName = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw ExtractionError.invalidArchive("CD entry \(i) filename is not valid UTF-8")
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
            throw ExtractionError.invalidArchive("Central directory contains 0 entries")
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
