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
        let zipURL = try TestZIPBuilder.createZIP(in: tempDir, files: [
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

        // Verify file contents
        let crateContent = try String(contentsOf: driveURL.appendingPathComponent("E-Maps/crate.xml"))
        XCTAssertEqual(crateContent, "<crate/>")

        // Verify progress was reported
        XCTAssertFalse(progressUpdates.isEmpty)
        XCTAssertGreaterThan(progressUpdates.last!.0, 0.9)
    }
}
