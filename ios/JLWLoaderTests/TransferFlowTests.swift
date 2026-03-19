import XCTest
@testable import JLWLoader

final class TransferFlowTests: XCTestCase {

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

    func testFullTransferWipesAndExtracts() async throws {
        // Set up a "USB drive" with old data
        let driveURL = tempDir.appendingPathComponent("usb")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)
        try "old".write(
            to: driveURL.appendingPathComponent("old.txt"),
            atomically: true,
            encoding: .utf8
        )
        let oldSubdir = driveURL.appendingPathComponent("oldsubdir")
        try FileManager.default.createDirectory(at: oldSubdir, withIntermediateDirectories: true)
        try "stale".write(
            to: oldSubdir.appendingPathComponent("stale.dat"),
            atomically: true,
            encoding: .utf8
        )

        // Create a ZIP with test files matching avionics structure
        let zipURL = try createTestZIP(files: [
            "E-Maps/crate.xml": "<crate/>",
            "E-Maps/E-Maps/chart.LUH": "data",
            "J7_Americas/nav.ACM": "navdata",
        ])

        let manager = USBTransferManager()
        var progressUpdates: [(Double, String)] = []

        let fileCount = try await manager.transfer(
            zipAt: zipURL,
            to: driveURL,
            requiredBytes: 1000
        ) { progress, detail in
            progressUpdates.append((progress, detail))
        }

        // Verify old files gone
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: driveURL.appendingPathComponent("old.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: driveURL.appendingPathComponent("oldsubdir").path
        ))

        // Verify new files present
        XCTAssertEqual(fileCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: driveURL.appendingPathComponent("E-Maps/crate.xml").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: driveURL.appendingPathComponent("E-Maps/E-Maps/chart.LUH").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: driveURL.appendingPathComponent("J7_Americas/nav.ACM").path
        ))

        // Verify file contents are correct
        let crateContent = try String(contentsOf: driveURL.appendingPathComponent("E-Maps/crate.xml"))
        XCTAssertEqual(crateContent, "<crate/>")

        // Verify progress was reported
        XCTAssertFalse(progressUpdates.isEmpty)
        XCTAssertGreaterThan(progressUpdates.last!.0, 0.9)
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
