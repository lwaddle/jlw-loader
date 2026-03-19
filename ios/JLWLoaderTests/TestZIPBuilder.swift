import Foundation

/// Builds valid ZIP files with stored (method 0) entries for testing.
/// No external tools needed — constructs ZIP binary data in memory.
enum TestZIPBuilder {

    /// Create a ZIP file at the given directory with the specified files.
    /// Keys are relative paths, values are file contents as strings.
    static func createZIP(in directory: URL, files: [String: String]) throws -> URL {
        let zipData = buildZIPData(files: files)
        let zipURL = directory.appendingPathComponent("test.zip")
        try zipData.write(to: zipURL)
        return zipURL
    }

    static func buildZIPData(files: [String: String]) -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var fileCount: UInt16 = 0

        let sortedFiles = files.sorted { $0.key < $1.key }

        // Collect directories
        var directories = Set<String>()
        for (path, _) in sortedFiles {
            let components = path.split(separator: "/").dropLast()
            var dir = ""
            for component in components {
                dir += component + "/"
                directories.insert(dir)
            }
        }

        // Directory entries
        for dirName in directories.sorted() {
            let localHeaderOffset = UInt32(zipData.count)
            let nameData = Data(dirName.utf8)

            zipData.append(contentsOf: localFileHeader(nameData: nameData, compressedSize: 0, uncompressedSize: 0, crc32: 0))
            zipData.append(nameData)

            centralDirectory.append(contentsOf: centralDirectoryEntry(nameData: nameData, compressedSize: 0, uncompressedSize: 0, crc32: 0, localHeaderOffset: localHeaderOffset))
            centralDirectory.append(nameData)

            fileCount += 1
        }

        // File entries
        for (path, content) in sortedFiles {
            let localHeaderOffset = UInt32(zipData.count)
            let nameData = Data(path.utf8)
            let contentData = Data(content.utf8)
            let crc = crc32Checksum(contentData)

            zipData.append(contentsOf: localFileHeader(nameData: nameData, compressedSize: UInt32(contentData.count), uncompressedSize: UInt32(contentData.count), crc32: crc))
            zipData.append(nameData)
            zipData.append(contentData)

            centralDirectory.append(contentsOf: centralDirectoryEntry(nameData: nameData, compressedSize: UInt32(contentData.count), uncompressedSize: UInt32(contentData.count), crc32: crc, localHeaderOffset: localHeaderOffset))
            centralDirectory.append(nameData)

            fileCount += 1
        }

        // End of central directory
        let centralDirOffset = UInt32(zipData.count)
        zipData.append(centralDirectory)

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.append(contentsOf: uint16LE(0))
        eocd.append(contentsOf: uint16LE(0))
        eocd.append(contentsOf: uint16LE(fileCount))
        eocd.append(contentsOf: uint16LE(fileCount))
        eocd.append(contentsOf: uint32LE(UInt32(centralDirectory.count)))
        eocd.append(contentsOf: uint32LE(centralDirOffset))
        eocd.append(contentsOf: uint16LE(0))
        zipData.append(eocd)

        return zipData
    }

    /// Create a ZIP that mimics macOS ditto/Finder: data descriptors with zeroed
    /// sizes in local file headers (bit 3 set). Central directory has correct sizes.
    /// This is the format that triggered the original extraction bug.
    static func createDataDescriptorZIP(in directory: URL, files: [String: String]) throws -> URL {
        let zipData = buildDataDescriptorZIPData(files: files)
        let zipURL = directory.appendingPathComponent("ditto-test.zip")
        try zipData.write(to: zipURL)
        return zipURL
    }

    static func buildDataDescriptorZIPData(files: [String: String]) -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var fileCount: UInt16 = 0

        let sortedFiles = files.sorted { $0.key < $1.key }

        for (path, content) in sortedFiles {
            let localHeaderOffset = UInt32(zipData.count)
            let nameData = Data(path.utf8)
            let contentData = Data(content.utf8)
            let crc = crc32Checksum(contentData)
            let compressedSize = UInt32(contentData.count)
            let uncompressedSize = UInt32(contentData.count)

            // Local file header with bit 3 set, sizes zeroed (data descriptor style)
            zipData.append(contentsOf: localFileHeader(
                nameData: nameData,
                compressedSize: 0,          // zeroed — sizes are in data descriptor
                uncompressedSize: 0,         // zeroed
                crc32: 0,                    // zeroed
                flags: 0x0008               // bit 3 set
            ))
            zipData.append(nameData)
            zipData.append(contentData)

            // Data descriptor (with signature)
            zipData.append(contentsOf: [0x50, 0x4B, 0x07, 0x08])  // signature
            zipData.append(contentsOf: uint32LE(crc))
            zipData.append(contentsOf: uint32LE(compressedSize))
            zipData.append(contentsOf: uint32LE(uncompressedSize))

            // Central directory has the REAL sizes
            centralDirectory.append(contentsOf: centralDirectoryEntry(
                nameData: nameData,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc,
                localHeaderOffset: localHeaderOffset
            ))
            centralDirectory.append(nameData)

            fileCount += 1
        }

        // End of central directory
        let centralDirOffset = UInt32(zipData.count)
        zipData.append(centralDirectory)

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.append(contentsOf: uint16LE(0))
        eocd.append(contentsOf: uint16LE(0))
        eocd.append(contentsOf: uint16LE(fileCount))
        eocd.append(contentsOf: uint16LE(fileCount))
        eocd.append(contentsOf: uint32LE(UInt32(centralDirectory.count)))
        eocd.append(contentsOf: uint32LE(centralDirOffset))
        eocd.append(contentsOf: uint16LE(0))
        zipData.append(eocd)

        return zipData
    }

    // MARK: - ZIP Structure Helpers

    private static func localFileHeader(nameData: Data, compressedSize: UInt32, uncompressedSize: UInt32, crc32: UInt32, flags: UInt16 = 0) -> [UInt8] {
        var header: [UInt8] = []
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        header.append(contentsOf: uint16LE(20))
        header.append(contentsOf: uint16LE(flags))
        header.append(contentsOf: uint16LE(0))
        header.append(contentsOf: uint16LE(0))
        header.append(contentsOf: uint16LE(0))
        header.append(contentsOf: uint32LE(crc32))
        header.append(contentsOf: uint32LE(compressedSize))
        header.append(contentsOf: uint32LE(uncompressedSize))
        header.append(contentsOf: uint16LE(UInt16(nameData.count)))
        header.append(contentsOf: uint16LE(0))
        return header
    }

    private static func centralDirectoryEntry(nameData: Data, compressedSize: UInt32, uncompressedSize: UInt32, crc32: UInt32, localHeaderOffset: UInt32) -> [UInt8] {
        var entry: [UInt8] = []
        entry.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        entry.append(contentsOf: uint16LE(20))
        entry.append(contentsOf: uint16LE(20))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint32LE(crc32))
        entry.append(contentsOf: uint32LE(compressedSize))
        entry.append(contentsOf: uint32LE(uncompressedSize))
        entry.append(contentsOf: uint16LE(UInt16(nameData.count)))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint16LE(0))
        entry.append(contentsOf: uint32LE(0))
        entry.append(contentsOf: uint32LE(localHeaderOffset))
        return entry
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
