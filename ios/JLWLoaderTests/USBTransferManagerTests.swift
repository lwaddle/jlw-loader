import XCTest
@testable import JLWLoader

final class USBTransferManagerTests: XCTestCase {
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

    func testWipeDriveRemovesAllContents() async throws {
        let driveURL = tempDir.appendingPathComponent("usb-drive")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)
        try "data".write(to: driveURL.appendingPathComponent("old-file.txt"), atomically: true, encoding: .utf8)
        let subdir = driveURL.appendingPathComponent("old-folder")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "data".write(to: subdir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        let manager = USBTransferManager()
        try await manager.wipeDrive(at: driveURL)

        let contents = try FileManager.default.contentsOfDirectory(atPath: driveURL.path)
        XCTAssertTrue(contents.isEmpty, "Drive should be empty after wipe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: driveURL.path), "Drive root should still exist")
    }

    func testWipeEmptyDriveSucceeds() async throws {
        let driveURL = tempDir.appendingPathComponent("empty-drive")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)

        let manager = USBTransferManager()
        try await manager.wipeDrive(at: driveURL)

        let contents = try FileManager.default.contentsOfDirectory(atPath: driveURL.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testCheckDriveSpaceWithSufficientSpace() async throws {
        let driveURL = tempDir.appendingPathComponent("space-drive")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)

        let manager = USBTransferManager()
        let result = try await manager.checkDriveSpace(at: driveURL, requiredBytes: 100)
        XCTAssertTrue(result, "Simulator temp dir should have >100 bytes free")
    }
}
