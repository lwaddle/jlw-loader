import XCTest
@testable import JLWLoader

final class ManifestTests: XCTestCase {
    func testDecodeManifest() throws {
        let json = """
        {
            "orgId": "jlw-aviation",
            "packageFilename": "update-2026-03.zip",
            "packageSizeBytes": 187234816,
            "packageChecksum": "sha256:abc123def456",
            "uploadedAt": "2026-03-17T16:30:00Z"
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(Manifest.self, from: json)
        XCTAssertEqual(manifest.orgId, "jlw-aviation")
        XCTAssertEqual(manifest.packageFilename, "update-2026-03.zip")
        XCTAssertEqual(manifest.packageSizeBytes, 187234816)
        XCTAssertEqual(manifest.packageChecksum, "sha256:abc123def456")
        XCTAssertEqual(manifest.uploadedAt, "2026-03-17T16:30:00Z")
    }

    func testDecodeEmptyManifest() throws {
        let json = """
        {
            "orgId": "jlw-aviation",
            "version": null,
            "message": "No update package uploaded yet"
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(Manifest.self, from: json)
        XCTAssertEqual(manifest.orgId, "jlw-aviation")
        XCTAssertNil(manifest.packageFilename)
        XCTAssertNil(manifest.uploadedAt)
    }

    func testSha256Value() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "test.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc123",
            uploadedAt: "2026-03-17T16:30:00Z"
        )
        XCTAssertEqual(manifest.sha256Value, "abc123")
    }

    func testSha256ValueNilWhenNoChecksum() {
        let manifest = Manifest(orgId: "test")
        XCTAssertNil(manifest.sha256Value)
    }
}
