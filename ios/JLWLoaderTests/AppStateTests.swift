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

        // No previous download or transfer — should be new update
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: nil,
            lastTransferredAt: nil,
            hasLocalPackage: false
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

        // Transferred after upload — up to date
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-18T09:00:00Z",
            lastTransferredAt: "2026-03-18T10:00:00Z",
            hasLocalPackage: false
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

        // Downloaded before new upload, previously transferred — new update
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-17T09:00:00Z",
            lastTransferredAt: "2026-03-17T10:00:00Z",
            hasLocalPackage: false
        )
        XCTAssertEqual(status, .updateAvailable)
    }

    func testUpdateStatusNoPackage() {
        let manifest = Manifest(orgId: "test")

        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: nil,
            lastTransferredAt: nil,
            hasLocalPackage: false
        )
        XCTAssertEqual(status, .upToDate)
    }

    // MARK: - New Transfer-Aware Tests

    func testStatusReadyToTransferWhenDownloadedButNotTransferred() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "update.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc",
            uploadedAt: "2026-03-17T16:30:00Z"
        )

        // Downloaded after upload, never transferred, package exists on disk
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-18T09:00:00Z",
            lastTransferredAt: nil,
            hasLocalPackage: true
        )
        XCTAssertEqual(status, .readyToTransfer)
    }

    func testStatusUpdateAvailableWhenTransferredButNewUpload() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "update.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc",
            uploadedAt: "2026-03-20T16:30:00Z"
        )

        // Transferred an older version, new upload available
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-17T09:00:00Z",
            lastTransferredAt: "2026-03-17T10:00:00Z",
            hasLocalPackage: false
        )
        XCTAssertEqual(status, .updateAvailable)
    }

    func testStatusUpToDateWhenTransferred() {
        let manifest = Manifest(
            orgId: "test",
            packageFilename: "update.zip",
            packageSizeBytes: 100,
            packageChecksum: "sha256:abc",
            uploadedAt: "2026-03-17T16:30:00Z"
        )

        // Transferred after upload — fully up to date
        let status = AppState.determineStatus(
            manifest: manifest,
            lastDownloadedAt: "2026-03-17T17:00:00Z",
            lastTransferredAt: "2026-03-17T18:00:00Z",
            hasLocalPackage: false
        )
        XCTAssertEqual(status, .upToDate)
    }
}
