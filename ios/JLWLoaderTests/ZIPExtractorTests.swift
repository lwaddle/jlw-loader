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
        let zipURL = try TestZIPBuilder.createZIP(in: tempDir, files: [
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

    /// Regression test: ZIPs created by macOS ditto/Finder use data descriptors
    /// (bit 3 of general purpose flag) with zeroed sizes in local file headers.
    /// The central directory has the correct sizes.
    func testExtractDataDescriptorZIP() async throws {
        let zipURL = try TestZIPBuilder.createDataDescriptorZIP(in: tempDir, files: [
            "file1.txt": "Hello from ditto",
            "subdir/file2.txt": "Nested content"
        ])

        let destDir = tempDir.appendingPathComponent("ditto-output")

        let count = try await ZIPExtractor.extract(zipAt: zipURL, to: destDir) { _, _ in }

        XCTAssertEqual(count, 2, "Should extract 2 files even with data descriptors")

        let content1 = try String(contentsOf: destDir.appendingPathComponent("file1.txt"))
        XCTAssertEqual(content1, "Hello from ditto")

        let content2 = try String(contentsOf: destDir.appendingPathComponent("subdir/file2.txt"))
        XCTAssertEqual(content2, "Nested content")
    }

    func testExtractToNonexistentDirectory() async throws {
        let zipURL = try TestZIPBuilder.createZIP(in: tempDir, files: ["a.txt": "test"])
        let destDir = tempDir.appendingPathComponent("does-not-exist")

        let count = try await ZIPExtractor.extract(zipAt: zipURL, to: destDir) { _, _ in }
        XCTAssertEqual(count, 1)
    }
}
