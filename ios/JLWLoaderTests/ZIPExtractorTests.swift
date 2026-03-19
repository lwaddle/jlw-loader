import XCTest
@testable import JLWLoader

final class ZIPExtractorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testExtractValidZIP() async throws {
        let zipURL = try createTestZIP(files: [
            "file1.txt": "Hello",
            "subdir/file2.txt": "World"
        ])

        let destDir = tempDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var progressUpdates: [(Int, Int)] = []
        let count = try await ZIPExtractor.extract(
            zipAt: zipURL,
            to: destDir,
            onProgress: { current, total in
                progressUpdates.append((current, total))
            }
        )

        XCTAssertEqual(count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("file1.txt").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("subdir/file2.txt").path
        ))

        let content = try String(contentsOf: destDir.appendingPathComponent("file1.txt"))
        XCTAssertEqual(content, "Hello")

        XCTAssertFalse(progressUpdates.isEmpty)
        XCTAssertEqual(progressUpdates.last?.0, 2)
        XCTAssertEqual(progressUpdates.last?.1, 2)
    }

    func testExtractToNonexistentDirectory() async throws {
        let zipURL = try createTestZIP(files: ["a.txt": "test"])
        let destDir = tempDir.appendingPathComponent("does-not-exist")

        let count = try await ZIPExtractor.extract(zipAt: zipURL, to: destDir) { _, _ in }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Helpers

    /// Builds a valid ZIP file with stored (method 0) entries — no external tools needed.
    private func createTestZIP(files: [String: String]) throws -> URL {
        var zipData = Data()
        var centralDirectory = Data()
        var fileCount: UInt16 = 0

        // Sort keys for deterministic output
        let sortedFiles = files.sorted { $0.key < $1.key }

        // Collect directories we need to create entries for
        var directories = Set<String>()
        for (path, _) in sortedFiles {
            let components = path.split(separator: "/").dropLast()
            var dir = ""
            for component in components {
                dir += component + "/"
                directories.insert(dir)
            }
        }

        // Write directory entries first
        for dirName in directories.sorted() {
            let localHeaderOffset = UInt32(zipData.count)
            let nameData = Data(dirName.utf8)

            // Local file header
            zipData.append(contentsOf: localFileHeader(
                nameData: nameData,
                compressedSize: 0,
                uncompressedSize: 0,
                crc32: 0
            ))
            zipData.append(nameData)

            // Central directory entry
            centralDirectory.append(contentsOf: centralDirectoryEntry(
                nameData: nameData,
                compressedSize: 0,
                uncompressedSize: 0,
                crc32: 0,
                localHeaderOffset: localHeaderOffset
            ))
            centralDirectory.append(nameData)

            fileCount += 1
        }

        // Write file entries
        for (path, content) in sortedFiles {
            let localHeaderOffset = UInt32(zipData.count)
            let nameData = Data(path.utf8)
            let contentData = Data(content.utf8)
            let crc = crc32Checksum(contentData)

            // Local file header
            zipData.append(contentsOf: localFileHeader(
                nameData: nameData,
                compressedSize: UInt32(contentData.count),
                uncompressedSize: UInt32(contentData.count),
                crc32: crc
            ))
            zipData.append(nameData)
            zipData.append(contentData)

            // Central directory entry
            centralDirectory.append(contentsOf: centralDirectoryEntry(
                nameData: nameData,
                compressedSize: UInt32(contentData.count),
                uncompressedSize: UInt32(contentData.count),
                crc32: crc,
                localHeaderOffset: localHeaderOffset
            ))
            centralDirectory.append(nameData)

            fileCount += 1
        }

        // End of central directory record
        let centralDirOffset = UInt32(zipData.count)
        zipData.append(centralDirectory)

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // Signature
        eocd.append(contentsOf: uint16LE(0))                // Disk number
        eocd.append(contentsOf: uint16LE(0))                // Disk with central dir
        eocd.append(contentsOf: uint16LE(fileCount))        // Entries on this disk
        eocd.append(contentsOf: uint16LE(fileCount))        // Total entries
        eocd.append(contentsOf: uint32LE(UInt32(centralDirectory.count))) // Central dir size
        eocd.append(contentsOf: uint32LE(centralDirOffset)) // Offset
        eocd.append(contentsOf: uint16LE(0))                // Comment length
        zipData.append(eocd)

        let zipURL = tempDir.appendingPathComponent("test.zip")
        try zipData.write(to: zipURL)
        return zipURL
    }

    private func localFileHeader(
        nameData: Data,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        crc32: UInt32
    ) -> [UInt8] {
        var header: [UInt8] = []
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // Local file header signature
        header.append(contentsOf: uint16LE(20))               // Version needed (2.0)
        header.append(contentsOf: uint16LE(0))                // General purpose bit flag
        header.append(contentsOf: uint16LE(0))                // Compression method: stored
        header.append(contentsOf: uint16LE(0))                // Last mod file time
        header.append(contentsOf: uint16LE(0))                // Last mod file date
        header.append(contentsOf: uint32LE(crc32))            // CRC-32
        header.append(contentsOf: uint32LE(compressedSize))   // Compressed size
        header.append(contentsOf: uint32LE(uncompressedSize)) // Uncompressed size
        header.append(contentsOf: uint16LE(UInt16(nameData.count))) // File name length
        header.append(contentsOf: uint16LE(0))                // Extra field length
        return header
    }

    private func centralDirectoryEntry(
        nameData: Data,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        crc32: UInt32,
        localHeaderOffset: UInt32
    ) -> [UInt8] {
        var entry: [UInt8] = []
        entry.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])  // Central dir signature
        entry.append(contentsOf: uint16LE(20))                // Version made by
        entry.append(contentsOf: uint16LE(20))                // Version needed
        entry.append(contentsOf: uint16LE(0))                 // General purpose bit flag
        entry.append(contentsOf: uint16LE(0))                 // Compression method: stored
        entry.append(contentsOf: uint16LE(0))                 // Last mod file time
        entry.append(contentsOf: uint16LE(0))                 // Last mod file date
        entry.append(contentsOf: uint32LE(crc32))             // CRC-32
        entry.append(contentsOf: uint32LE(compressedSize))    // Compressed size
        entry.append(contentsOf: uint32LE(uncompressedSize))  // Uncompressed size
        entry.append(contentsOf: uint16LE(UInt16(nameData.count))) // File name length
        entry.append(contentsOf: uint16LE(0))                 // Extra field length
        entry.append(contentsOf: uint16LE(0))                 // File comment length
        entry.append(contentsOf: uint16LE(0))                 // Disk number start
        entry.append(contentsOf: uint16LE(0))                 // Internal file attributes
        entry.append(contentsOf: uint32LE(0))                 // External file attributes
        entry.append(contentsOf: uint32LE(localHeaderOffset)) // Relative offset
        return entry
    }

    private func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    /// Simple CRC-32 implementation for test data.
    private func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
