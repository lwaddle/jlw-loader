import XCTest
@testable import JLWLoader

final class AppStateTests: XCTestCase {

    func testUpdateStatusNewUpdateAvailable() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "update.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc",
            uploadedAt: "2026-03-17T16:30:00Z"
        )

        // No previous download — should be new update
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: nil
        )
        XCTAssertEqual(status, .updateAvailable)
    }

    func testUpdateStatusUpToDate() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "update.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc",
            uploadedAt: "2026-03-17T16:30:00Z"
        )

        // Downloaded after upload — up to date
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-18T09:00:00Z"
        )
        XCTAssertEqual(status, .upToDate)
    }

    func testUpdateStatusNewUpdateAfterPreviousDownload() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "update.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc",
            uploadedAt: "2026-03-20T16:30:00Z"
        )

        // Downloaded before new upload — new update
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-17T09:00:00Z"
        )
        XCTAssertEqual(status, .updateAvailable)
    }

    func testUpdateStatusNoPackage() {
        let manifest = Manifest(orgId: "test")

        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: nil
        )
        XCTAssertEqual(status, .upToDate)
    }
}
