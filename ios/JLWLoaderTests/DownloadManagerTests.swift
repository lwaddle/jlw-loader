import XCTest
@testable import JLWLoader

final class DownloadManagerTests: XCTestCase {

    func testComputeSHA256() async throws {
        // "hello world" SHA-256 = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-checksum.txt")
        try "hello world".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hash = try DownloadManager.computeSHA256(of: tempURL)
        XCTAssertEqual(hash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func testDocumentsDirectory() {
        let dir = DownloadManager.documentsDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }
}
