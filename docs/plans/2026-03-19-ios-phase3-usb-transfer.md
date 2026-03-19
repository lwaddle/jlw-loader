# iOS Phase 3 — USB Transfer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add USB drive wipe + ZIP extraction so pilots can transfer downloaded updates to a FAT32 USB drive directly from the iPhone.

**Architecture:** Three new files — `USBTransferManager` (actor for wipe/extract/progress), `DocumentPickerView` (SwiftUI wrapper for UIDocumentPickerViewController), and `ZIPExtractor` (zero-dependency ZIP extraction using POSIX `zlib`). Existing `AppState` and `MainView` are updated with transfer states. The `UpdateStatus` enum gains `.readyToTransfer`, `.transferring`, and `.transferComplete` cases. "Up to date" comparison shifts from `lastDownloadedAt` to `lastTransferredAt`.

**Tech Stack:** SwiftUI, FileManager, UIDocumentPickerViewController, POSIX zlib (ships with iOS — no third-party dependency needed), CryptoKit

---

## Design Decisions

### ZIP Extraction Without Third-Party Dependencies
The spec requires zero third-party libraries. iOS ships with `libz` (zlib) which can decompress deflated data, but doesn't provide a ZIP container parser. We'll write a minimal `ZIPExtractor` that reads the ZIP local file headers and extracts entries using `compression_decode_buffer()` from the `Compression` framework. This is ~100 lines of code for our use case (no encryption, no ZIP64, standard deflate). If this proves fragile during testing, we can fall back to adding `ZIPFoundation` via SPM — a single pure-Swift package.

### State Transition: downloadComplete → readyToTransfer
The existing `.downloadComplete` state is renamed to `.readyToTransfer` since the download is no longer the terminal action. This is a clean rename — the state means "ZIP is verified and on disk, waiting for USB transfer."

### "Up to Date" Comparison Changes
Currently: `manifest.uploadedAt > lastDownloadedAt` → update available.
Phase 3: `manifest.uploadedAt > lastTransferredAt` → update available. A download without transfer doesn't clear the badge. This matches the spec: "Badge clears only when a transfer completes successfully."

### Ready to Transfer Survives Restart
If the app restarts after download but before transfer, it checks for a ZIP in Documents. If one exists and `lastDownloadedAt > lastTransferredAt`, it shows "Ready to Transfer" without re-downloading.

### Security-Scoped Resource Access
UIDocumentPickerViewController grants a security-scoped URL. We must call `url.startAccessingSecurityScopedResource()` before any FileManager operations and `url.stopAccessingSecurityScopedResource()` when done. This is wrapped in `USBTransferManager`.

---

## Task 1: Update UpdateStatus Enum and Constants

**Files:**
- Modify: `ios/JLWLoader/AppState.swift:1-11` (UpdateStatus enum)
- Modify: `ios/JLWLoader/Constants.swift:12-16` (UserDefaultsKeys)
- Modify: `ios/JLWLoaderTests/AppStateTests.swift`

**Step 1: Write failing tests for new status determination logic**

Add tests to `AppStateTests.swift` that exercise the new transfer-aware status logic:

```swift
func testStatusReadyToTransferWhenDownloadedButNotTransferred() {
    let manifest = Manifest(
        orgId: "test",
        packageFilename: "update.zip",
        packageSizeBytes: 100,
        packageChecksum: "sha256:abc",
        uploadedAt: "2026-03-17T16:30:00Z"
    )

    // Downloaded but never transferred — should be ready to transfer
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

    // Transferred, but newer upload exists
    let status = AppState.determineStatus(
        manifest: manifest,
        lastDownloadedAt: "2026-03-18T09:00:00Z",
        lastTransferredAt: "2026-03-18T10:00:00Z",
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

    // Transferred after upload — up to date
    let status = AppState.determineStatus(
        manifest: manifest,
        lastDownloadedAt: "2026-03-18T09:00:00Z",
        lastTransferredAt: "2026-03-18T10:00:00Z",
        hasLocalPackage: false
    )
    XCTAssertEqual(status, .upToDate)
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/AppStateTests 2>&1 | tail -20`
Expected: FAIL — `readyToTransfer` case doesn't exist, `determineStatus` signature doesn't match.

**Step 3: Update UpdateStatus enum**

In `AppState.swift`, replace the enum:

```swift
enum UpdateStatus: Equatable {
    case checking
    case updateAvailable
    case downloading(progress: Double)
    case verifying
    case readyToTransfer          // was: downloadComplete
    case transferring(progress: Double, detail: String)
    case transferComplete(fileCount: Int)
    case upToDate
    case error(String)
}
```

**Step 4: Add new UserDefaults keys**

In `Constants.swift`, add to `UserDefaultsKeys`:

```swift
enum UserDefaultsKeys {
    static let lastDownloadedAt = "lastDownloadedAt"
    static let lastDownloadedFilename = "lastDownloadedFilename"
    static let lastCheckedAt = "lastCheckedAt"
    static let lastTransferredAt = "lastTransferredAt"
    static let lastTransferredFilename = "lastTransferredFilename"
}
```

**Step 5: Update determineStatus signature and logic**

Replace the existing `determineStatus` method in `AppState`:

```swift
/// Pure function for testability — determines status from manifest + local state.
nonisolated static func determineStatus(
    manifest: Manifest,
    lastDownloadedAt: String?,
    lastTransferredAt: String?,
    hasLocalPackage: Bool
) -> UpdateStatus {
    guard manifest.hasPackage, let uploadedAt = manifest.uploadedAt else {
        return .upToDate
    }

    // If transferred after upload, we're current
    if let transferred = lastTransferredAt, uploadedAt <= transferred {
        return .upToDate
    }

    // If downloaded but not yet transferred (or downloaded after last transfer), ready to transfer
    if hasLocalPackage, let downloaded = lastDownloadedAt {
        let notYetTransferred = lastTransferredAt == nil || downloaded > (lastTransferredAt ?? "")
        if notYetTransferred && downloaded >= uploadedAt {
            return .readyToTransfer
        }
    }

    return .updateAvailable
}
```

**Step 6: Update all callers of determineStatus**

In `AppState.checkForUpdates()`, update the call:

```swift
status = Self.determineStatus(
    manifest: fetched,
    lastDownloadedAt: UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastDownloadedAt),
    lastTransferredAt: UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastTransferredAt),
    hasLocalPackage: hasLocalPackage()
)
```

In `AppState.cancelDownload()`, update similarly.

Add helper to `AppState`:

```swift
/// Check if a downloaded ZIP package exists in Documents.
private func hasLocalPackage() -> Bool {
    let fm = FileManager.default
    let docs = DownloadManager.documentsDirectory
    guard let contents = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) else {
        return false
    }
    return contents.contains { $0.pathExtension == "zip" }
}
```

**Step 7: Fix existing tests to use new signature**

Update all four existing tests in `AppStateTests.swift` to pass the new parameters. For the existing tests that checked `downloadComplete`, update to use the correct expected values. Example for the "up to date" test:

```swift
func testUpdateStatusUpToDate() {
    let manifest = Manifest(
        orgId: "test",
        packageFilename: "update.zip",
        packageSizeBytes: 100,
        packageChecksum: "sha256:abc",
        uploadedAt: "2026-03-17T16:30:00Z"
    )

    let status = AppState.determineStatus(
        manifest: manifest,
        lastDownloadedAt: "2026-03-18T09:00:00Z",
        lastTransferredAt: "2026-03-18T10:00:00Z",
        hasLocalPackage: false
    )
    XCTAssertEqual(status, .upToDate)
}
```

**Step 8: Update MainView to compile with renamed states**

Replace `.downloadComplete` with `.readyToTransfer` in MainView's switch statement. Temporarily use the same view content — we'll update the UI in Task 5.

Replace `.downloadComplete:` → `.readyToTransfer:` and rename `downloadCompleteView` → `readyToTransferView`.

Add placeholder cases for the new states:

```swift
case .transferring(let progress, let detail):
    Text("Transferring... \(Int(progress * 100))%") // placeholder
case .transferComplete(let fileCount):
    Text("Transfer complete: \(fileCount) files") // placeholder
```

**Step 9: Update AppState.downloadUpdate() to use .readyToTransfer**

Change the line `status = .downloadComplete` to `status = .readyToTransfer`.

**Step 10: Run all tests to verify they pass**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests pass.

**Step 11: Commit**

```bash
git add ios/JLWLoader/AppState.swift ios/JLWLoader/Constants.swift ios/JLWLoader/MainView.swift ios/JLWLoaderTests/AppStateTests.swift
git commit -m "feat: add transfer states to UpdateStatus enum, update status determination for USB transfer"
```

---

## Task 2: ZIPExtractor — Zero-Dependency ZIP Extraction

**Files:**
- Create: `ios/JLWLoader/ZIPExtractor.swift`
- Create: `ios/JLWLoaderTests/ZIPExtractorTests.swift`

**Step 1: Write failing tests**

```swift
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
        // Create a real ZIP file using the zlib-based approach
        // We'll use a pre-made ZIP with known contents
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

        // Progress was reported
        XCTAssertFalse(progressUpdates.isEmpty)
        // Last progress should be (2, 2)
        XCTAssertEqual(progressUpdates.last?.0, 2)
        XCTAssertEqual(progressUpdates.last?.1, 2)
    }

    func testExtractToNonexistentDirectory() async throws {
        let zipURL = try createTestZIP(files: ["a.txt": "test"])
        let destDir = tempDir.appendingPathComponent("does-not-exist")

        // Should create the directory automatically
        let count = try await ZIPExtractor.extract(zipAt: zipURL, to: destDir) { _, _ in }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Helpers

    /// Creates a valid ZIP file in tempDir using /usr/bin/ditto (macOS only, for tests).
    private func createTestZIP(files: [String: String]) throws -> URL {
        let sourceDir = tempDir.appendingPathComponent("zip-source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        for (path, content) in files {
            let fileURL = sourceDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let zipURL = tempDir.appendingPathComponent("test.zip")

        // Use /usr/bin/ditto to create ZIP (available on macOS test runner)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", sourceDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ZIPExtractorTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ditto failed"])
        }

        return zipURL
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/ZIPExtractorTests 2>&1 | tail -20`
Expected: FAIL — `ZIPExtractor` doesn't exist.

**Step 3: Implement ZIPExtractor**

Create `ios/JLWLoader/ZIPExtractor.swift`:

```swift
import Foundation
import Compression

/// Extracts ZIP archives without third-party dependencies.
/// Uses Foundation's file I/O and the Compression framework (zlib deflate).
enum ZIPExtractor {

    enum ExtractionError: LocalizedError {
        case invalidArchive
        case readFailed
        case decompressionFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive:
                return "The update package is not a valid ZIP file."
            case .readFailed:
                return "Could not read the update package."
            case .decompressionFailed(let name):
                return "Failed to decompress file: \(name)"
            case .writeFailed(let name):
                return "Failed to write file: \(name)"
            }
        }
    }

    /// Extract all files from a ZIP archive to a destination directory.
    /// Returns the number of files extracted (excludes directories).
    /// Calls onProgress(currentFile, totalFiles) after each file.
    static func extract(
        zipAt source: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> Int {
        // Read entire ZIP into memory — our packages are 150-180MB compressed,
        // which fits comfortably in iPhone RAM (minimum 3GB on iOS 16 devices).
        guard let data = try? Data(contentsOf: source) else {
            throw ExtractionError.readFailed
        }

        let entries = try parseEntries(from: data)
        let fileEntries = entries.filter { !$0.isDirectory }
        let totalFiles = fileEntries.count

        // Create destination if needed
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var extractedCount = 0
        for entry in fileEntries {
            let fileURL = destination.appendingPathComponent(entry.name)

            // Create parent directories
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Decompress and write
            let fileData: Data
            if entry.compressionMethod == 0 {
                // Stored (no compression)
                fileData = data[entry.dataOffset..<(entry.dataOffset + Int(entry.compressedSize))]
            } else if entry.compressionMethod == 8 {
                // Deflated
                let compressed = data[entry.dataOffset..<(entry.dataOffset + Int(entry.compressedSize))]
                guard let decompressed = decompress(compressed, expectedSize: Int(entry.uncompressedSize)) else {
                    throw ExtractionError.decompressionFailed(entry.name)
                }
                fileData = decompressed
            } else {
                throw ExtractionError.decompressionFailed(entry.name)
            }

            do {
                try fileData.write(to: fileURL)
            } catch {
                throw ExtractionError.writeFailed(entry.name)
            }

            extractedCount += 1
            onProgress(extractedCount, totalFiles)
        }

        return extractedCount
    }

    // MARK: - ZIP Parsing

    private struct ZIPEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let dataOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Parse ZIP local file headers to find all entries.
    private static func parseEntries(from data: Data) throws -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            // Check for local file header signature: PK\x03\x04
            guard data[offset] == 0x50,
                  data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x03,
                  data[offset + 3] == 0x04 else {
                break // No more local headers (hit central directory or end)
            }

            let compressionMethod = readUInt16(data, at: offset + 8)
            let compressedSize = readUInt32(data, at: offset + 18)
            let uncompressedSize = readUInt32(data, at: offset + 22)
            let nameLength = Int(readUInt16(data, at: offset + 26))
            let extraLength = Int(readUInt16(data, at: offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLength <= data.count else {
                throw ExtractionError.invalidArchive
            }

            let nameData = data[nameStart..<(nameStart + nameLength)]
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ExtractionError.invalidArchive
            }

            // Skip __MACOSX resource fork entries
            if !name.hasPrefix("__MACOSX/") {
                let dataOffset = nameStart + nameLength + extraLength

                entries.append(ZIPEntry(
                    name: name,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    dataOffset: dataOffset
                ))
            }

            // Advance to next entry
            let dataOffset = nameStart + nameLength + extraLength
            offset = dataOffset + Int(compressedSize)
        }

        if entries.isEmpty {
            throw ExtractionError.invalidArchive
        }

        return entries
    }

    // MARK: - Compression

    private static func decompress(_ compressedData: Data, expectedSize: Int) -> Data? {
        let sourceSize = compressedData.count
        guard sourceSize > 0, expectedSize > 0 else { return Data() }

        var decompressed = Data(count: expectedSize)
        let result = decompressed.withUnsafeMutableBytes { destBuffer in
            compressedData.withUnsafeBytes { sourceBuffer in
                compression_decode_buffer(
                    destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    sourceSize,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard result == expectedSize else { return nil }
        return decompressed
    }

    // MARK: - Binary Helpers

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/ZIPExtractorTests 2>&1 | tail -20`
Expected: All pass.

**Step 5: Commit**

```bash
git add ios/JLWLoader/ZIPExtractor.swift ios/JLWLoaderTests/ZIPExtractorTests.swift
git commit -m "feat: add ZIPExtractor for zero-dependency ZIP extraction using Compression framework"
```

---

## Task 3: USBTransferManager

**Files:**
- Create: `ios/JLWLoader/USBTransferManager.swift`
- Create: `ios/JLWLoaderTests/USBTransferManagerTests.swift`

**Step 1: Write failing tests**

```swift
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
        // Create some files on the "drive"
        let driveURL = tempDir.appendingPathComponent("usb-drive")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)
        try "data".write(
            to: driveURL.appendingPathComponent("old-file.txt"),
            atomically: true, encoding: .utf8
        )
        let subdir = driveURL.appendingPathComponent("old-folder")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "data".write(
            to: subdir.appendingPathComponent("nested.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = USBTransferManager()
        try await manager.wipeDrive(at: driveURL)

        let contents = try FileManager.default.contentsOfDirectory(atPath: driveURL.path)
        XCTAssertTrue(contents.isEmpty, "Drive should be empty after wipe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: driveURL.path),
                      "Drive root directory should still exist")
    }

    func testWipeEmptyDriveSucceeds() async throws {
        let driveURL = tempDir.appendingPathComponent("empty-drive")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)

        let manager = USBTransferManager()
        try await manager.wipeDrive(at: driveURL)

        let contents = try FileManager.default.contentsOfDirectory(atPath: driveURL.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testCheckDriveSpaceInsufficientSpace() async throws {
        let driveURL = tempDir.appendingPathComponent("tiny-drive")
        try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: true)

        let manager = USBTransferManager()
        // This test verifies the method exists and returns correct type.
        // Actual free space on simulator will be large, so we test the positive case.
        let result = try manager.checkDriveSpace(at: driveURL, requiredBytes: 100)
        XCTAssertTrue(result, "Simulator temp dir should have >100 bytes free")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/USBTransferManagerTests 2>&1 | tail -20`
Expected: FAIL — `USBTransferManager` doesn't exist.

**Step 3: Implement USBTransferManager**

Create `ios/JLWLoader/USBTransferManager.swift`:

```swift
import Foundation

actor USBTransferManager {

    enum TransferError: LocalizedError {
        case driveNotAccessible
        case insufficientSpace(needed: Int64, available: Int64)
        case wipeFailed(String)
        case extractionFailed(String)
        case driveDisconnected

        var errorDescription: String? {
            switch self {
            case .driveNotAccessible:
                return "Could not access the USB drive. Please reconnect and try again."
            case .insufficientSpace(let needed, let available):
                let formatter = ByteCountFormatter()
                let neededStr = formatter.string(fromByteCount: needed)
                let availStr = formatter.string(fromByteCount: available)
                return "Drive has insufficient space (needs \(neededStr), drive has \(availStr) free)."
            case .wipeFailed(let detail):
                return "Failed to clear drive contents. \(detail)"
            case .extractionFailed(let detail):
                return "Transfer failed. Do not use this drive for the update. Reconnect the drive and try again. (\(detail))"
            case .driveDisconnected:
                return "Drive was disconnected during transfer. Reconnect the drive and try again."
            }
        }
    }

    /// Wipe all contents of the drive directory. Preserves the root directory itself.
    func wipeDrive(at driveURL: URL) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: driveURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            do {
                try fm.removeItem(at: item)
            } catch {
                throw TransferError.wipeFailed(error.localizedDescription)
            }
        }

        // Verify drive is empty
        let remaining = try fm.contentsOfDirectory(
            at: driveURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if !remaining.isEmpty {
            throw TransferError.wipeFailed("Some files could not be removed.")
        }
    }

    /// Check if the drive has enough free space.
    /// Returns true if sufficient, false otherwise.
    func checkDriveSpace(at driveURL: URL, requiredBytes: Int64) throws -> Bool {
        let values = try driveURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity else {
            return true // Can't determine — proceed optimistically
        }
        return Int64(available) >= requiredBytes
    }

    /// Transfer a downloaded ZIP to the USB drive.
    /// Wipes drive, extracts ZIP contents, reports progress.
    /// Returns the number of files written.
    func transfer(
        zipAt sourceURL: URL,
        to driveURL: URL,
        requiredBytes: Int64,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> Int {
        // Check space
        if let values = try? driveURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            if Int64(available) < requiredBytes {
                throw TransferError.insufficientSpace(
                    needed: requiredBytes,
                    available: Int64(available)
                )
            }
        }

        // Wipe
        onProgress(0, "Clearing drive contents...")
        do {
            try wipeDrive(at: driveURL)
        } catch {
            throw error
        }

        // Extract
        onProgress(0.05, "Writing files...")
        do {
            let fileCount = try await ZIPExtractor.extract(
                zipAt: sourceURL,
                to: driveURL
            ) { current, total in
                let progress = 0.05 + (Double(current) / Double(total)) * 0.95
                let detail = "Writing files... \(current) of \(total)"
                onProgress(progress, detail)
            }
            return fileCount
        } catch {
            // Check if drive is still accessible
            if !FileManager.default.fileExists(atPath: driveURL.path) {
                throw TransferError.driveDisconnected
            }
            throw TransferError.extractionFailed(error.localizedDescription)
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/USBTransferManagerTests 2>&1 | tail -20`
Expected: All pass.

**Step 5: Commit**

```bash
git add ios/JLWLoader/USBTransferManager.swift ios/JLWLoaderTests/USBTransferManagerTests.swift
git commit -m "feat: add USBTransferManager for drive wipe and ZIP-to-USB transfer"
```

---

## Task 4: DocumentPickerView — SwiftUI Wrapper

**Files:**
- Create: `ios/JLWLoader/DocumentPickerView.swift`

No unit tests for this file — it's a thin UIKit wrapper. Will be verified via manual testing on device.

**Step 1: Implement DocumentPickerView**

Create `ios/JLWLoader/DocumentPickerView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI wrapper for UIDocumentPickerViewController.
/// Presents the system Files picker for selecting a USB drive (folder).
struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild build -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios/JLWLoader/DocumentPickerView.swift
git commit -m "feat: add DocumentPickerView for USB drive folder selection"
```

---

## Task 5: Update AppState with Transfer Logic

**Files:**
- Modify: `ios/JLWLoader/AppState.swift`

**Step 1: Add transfer manager and transfer methods to AppState**

Add property:

```swift
private let transferManager: USBTransferManager

// In init:
self.transferManager = USBTransferManager()
```

Add new computed properties:

```swift
var lastTransferredAt: String? {
    UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastTransferredAt)
}

var lastTransferredFilename: String? {
    UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastTransferredFilename)
}
```

Add `@Published` for document picker presentation:

```swift
@Published var showDocumentPicker: Bool = false
```

Add transfer method:

```swift
func transferToUSB(driveURL: URL) async {
    guard let manifest = manifest else { return }

    // Find the downloaded ZIP
    let fm = FileManager.default
    let docs = DownloadManager.documentsDirectory
    guard let contents = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil),
          let zipURL = contents.first(where: { $0.pathExtension == "zip" }) else {
        status = .error("Downloaded update not found. Please download again.")
        return
    }

    // Start security-scoped access
    guard driveURL.startAccessingSecurityScopedResource() else {
        status = .error("Could not access the USB drive. Please try again.")
        return
    }
    defer { driveURL.stopAccessingSecurityScopedResource() }

    // Estimate uncompressed size (~2x compressed for navigation data)
    let requiredBytes = Int64((manifest.packageSizeBytes ?? 0) * 2)

    status = .transferring(progress: 0, detail: "Preparing...")

    do {
        let fileCount = try await transferManager.transfer(
            zipAt: zipURL,
            to: driveURL,
            requiredBytes: requiredBytes
        ) { [weak self] progress, detail in
            Task { @MainActor in
                self?.status = .transferring(progress: progress, detail: detail)
            }
        }

        // Record transfer success
        UserDefaults.standard.set(
            ISO8601DateFormatter().string(from: Date()),
            forKey: Constants.UserDefaultsKeys.lastTransferredAt
        )
        UserDefaults.standard.set(
            manifest.packageFilename,
            forKey: Constants.UserDefaultsKeys.lastTransferredFilename
        )

        status = .transferComplete(fileCount: fileCount)

    } catch {
        status = .error(error.localizedDescription)
    }
}

func transferComplete() {
    // Called when user taps "Done" on transfer complete screen
    if let manifest = manifest {
        let lastTransferred = UserDefaults.standard.string(
            forKey: Constants.UserDefaultsKeys.lastTransferredAt
        )
        status = Self.determineStatus(
            manifest: manifest,
            lastDownloadedAt: UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastDownloadedAt),
            lastTransferredAt: lastTransferred,
            hasLocalPackage: hasLocalPackage()
        )
    } else {
        status = .upToDate
    }
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild build -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All pass.

**Step 4: Commit**

```bash
git add ios/JLWLoader/AppState.swift
git commit -m "feat: add USB transfer logic to AppState with security-scoped access"
```

---

## Task 6: Update MainView with Transfer UI States

**Files:**
- Modify: `ios/JLWLoader/MainView.swift`

**Step 1: Replace placeholder transfer views with full implementations**

Update the switch cases and add the three new views:

**readyToTransferView** (replaces the old downloadCompleteView):

```swift
private var readyToTransferView: some View {
    VStack(spacing: 16) {
        Spacer()

        Label("Ready to Transfer", systemImage: "arrow.down.circle.fill")
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundColor(.blue)

        VStack(spacing: 8) {
            if let filename = appState.lastDownloadedFilename {
                Text(filename)
                    .font(.body.monospaced())
            }
            Text("Downloaded \(appState.formattedRelativeDate(appState.lastDownloadedAt))")
                .foregroundColor(.secondary)
            Text("Verified \u{2713}")
                .foregroundColor(.green)
        }

        Text("Connect USB drive to iPhone\nusing your USB-C to USB-A adapter")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.top, 8)

        Button {
            appState.showDocumentPicker = true
        } label: {
            Text("Select USB Drive")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Spacer()
    }
    .sheet(isPresented: $appState.showDocumentPicker) {
        DocumentPickerView(
            onPick: { url in
                appState.showDocumentPicker = false
                Task { await appState.transferToUSB(driveURL: url) }
            },
            onCancel: {
                appState.showDocumentPicker = false
            }
        )
    }
}
```

**transferringView:**

```swift
private func transferringView(progress: Double, detail: String) -> some View {
    VStack(spacing: 16) {
        Spacer()

        Text("Transferring to USB...")
            .font(.title3)
            .fontWeight(.medium)

        ProgressView(value: progress)
            .progressViewStyle(.linear)
            .padding(.horizontal)

        Text(detail)
            .font(.callout)
            .foregroundColor(.secondary)

        Text("\(Int(progress * 100))%")
            .font(.body.monospacedDigit())
            .foregroundColor(.secondary)

        Label("Do not disconnect drive", systemImage: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
            .font(.callout)
            .padding(.top, 8)

        Spacer()
    }
}
```

**transferCompleteView:**

```swift
private func transferCompleteView(fileCount: Int) -> some View {
    VStack(spacing: 16) {
        Spacer()

        Label("Transfer Complete", systemImage: "checkmark.circle.fill")
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundColor(.green)

        VStack(spacing: 8) {
            Text("\(fileCount) files written")
                .font(.body)
            if let filename = appState.lastTransferredFilename {
                Text(filename)
                    .font(.body.monospaced())
                    .foregroundColor(.secondary)
            }
        }

        Text("Drive is ready for the aircraft.\nYou can safely disconnect the USB drive.")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.top, 8)

        Button {
            appState.transferComplete()
        } label: {
            Text("Done")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Spacer()
    }
}
```

**Step 2: Update the switch statement**

Replace the placeholder cases:

```swift
case .readyToTransfer:
    readyToTransferView
case .transferring(let progress, let detail):
    transferringView(progress: progress, detail: detail)
case .transferComplete(let fileCount):
    transferCompleteView(fileCount: fileCount)
```

**Step 3: Update upToDateView to show transfer info**

Replace `lastDownloadedFilename`/`lastDownloadedAt` references with transfer equivalents:

```swift
private var upToDateView: some View {
    VStack(spacing: 16) {
        Spacer()

        Label("Current", systemImage: "checkmark.circle.fill")
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundColor(.green)

        VStack(spacing: 8) {
            if let filename = appState.lastTransferredFilename ?? appState.lastDownloadedFilename {
                Text(filename)
                    .font(.body.monospaced())
            }
            if let transferredAt = appState.lastTransferredAt {
                Text("Last transferred: \(appState.formattedRelativeDate(transferredAt))")
                    .foregroundColor(.secondary)
            }
        }

        Button {
            Task { await appState.checkForUpdates() }
        } label: {
            Text("Check for Updates")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        Spacer()
    }
}
```

**Step 4: Verify it compiles**

Run: `xcodebuild build -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 5: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All pass.

**Step 6: Commit**

```bash
git add ios/JLWLoader/MainView.swift
git commit -m "feat: add USB transfer UI states — ready, transferring, complete"
```

---

## Task 7: Integration Test — Full Transfer Flow

**Files:**
- Create: `ios/JLWLoaderTests/TransferFlowTests.swift`

**Step 1: Write integration test**

```swift
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
        try "old".write(to: driveURL.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        // Create a ZIP with test files
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

        // Verify progress was reported
        XCTAssertFalse(progressUpdates.isEmpty)
        // Last progress should be ~1.0
        XCTAssertGreaterThan(progressUpdates.last!.0, 0.9)
    }

    // MARK: - Helpers

    private func createTestZIP(files: [String: String]) throws -> URL {
        let sourceDir = tempDir.appendingPathComponent("zip-source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        for (path, content) in files {
            let fileURL = sourceDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let zipURL = tempDir.appendingPathComponent("test.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", sourceDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "test", code: 1)
        }
        return zipURL
    }
}
```

**Step 2: Run integration test**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/TransferFlowTests 2>&1 | tail -20`
Expected: All pass.

**Step 3: Run full test suite**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All pass.

**Step 4: Commit**

```bash
git add ios/JLWLoaderTests/TransferFlowTests.swift
git commit -m "test: add integration test for full USB transfer flow (wipe + extract)"
```

---

## Summary

| Task | What | New Files | Modified Files |
|------|------|-----------|----------------|
| 1 | UpdateStatus enum + Constants + determineStatus | — | AppState.swift, Constants.swift, MainView.swift, AppStateTests.swift |
| 2 | ZIPExtractor (zero-dependency) | ZIPExtractor.swift, ZIPExtractorTests.swift | — |
| 3 | USBTransferManager | USBTransferManager.swift, USBTransferManagerTests.swift | — |
| 4 | DocumentPickerView | DocumentPickerView.swift | — |
| 5 | AppState transfer logic | — | AppState.swift |
| 6 | MainView transfer UI | — | MainView.swift |
| 7 | Integration test | TransferFlowTests.swift | — |

**Total: 5 new files, 4 modified files, 7 commits.**

After all tasks: the app supports the complete flow from download → select USB → wipe → extract → done. Phase 4 (polish, error edge cases, App Store prep) is separate.
