# iOS App Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build JLW Loader iOS app Phase 1 — access code auth, manifest check, ZIP download with checksum verification, stored locally on device.

**Architecture:** Single-screen SwiftUI app with an `ObservableObject`-based `AppState` driving all UI. `APIClient` handles networking, `DownloadManager` handles download + checksum, `KeychainService` wraps Keychain. No third-party deps.

**Tech Stack:** SwiftUI (iOS 16+), URLSession, CryptoKit, Keychain Services, xcodegen for project generation.

**Design doc:** `docs/plans/2026-03-18-ios-app-phase1-design.md`

---

### Task 1: Install xcodegen and scaffold Xcode project

**Files:**
- Create: `ios/project.yml`
- Create: `ios/JLWLoader/JLWLoaderApp.swift`
- Create: `ios/JLWLoader/Assets.xcassets/Contents.json`
- Create: `ios/JLWLoader/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `ios/JLWLoader/Assets.xcassets/AppIcon.appiconset/Contents.json`

**Step 1: Install xcodegen**

Run: `brew install xcodegen`
Expected: xcodegen installed successfully (or already installed)

**Step 2: Create project.yml**

Create `ios/project.yml`:

```yaml
name: JLWLoader
options:
  bundleIdPrefix: com.jlwav
  deploymentTarget:
    iOS: "16.0"
  xcodeVersion: "16.3"
settings:
  SWIFT_VERSION: "5.9"
targets:
  JLWLoader:
    type: application
    platform: iOS
    sources:
      - JLWLoader
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.jlwav.loader
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: 1
        TARGETED_DEVICE_FAMILY: 1
        INFOPLIST_GENERATION_MODE: GeneratedFile
        INFOPLIST_KEY_UILaunchScreen_Generation: true
        INFOPLIST_KEY_UISupportedInterfaceOrientations: UIInterfaceOrientationPortrait
        INFOPLIST_KEY_CFBundleDisplayName: JLW Loader
  JLWLoaderTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - JLWLoaderTests
    dependencies:
      - target: JLWLoader
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.jlwav.loader.tests
```

**Step 3: Create minimal app entry point**

Create `ios/JLWLoader/JLWLoaderApp.swift`:

```swift
import SwiftUI

@main
struct JLWLoaderApp: App {
    var body: some Scene {
        WindowGroup {
            Text("JLW Loader")
        }
    }
}
```

**Step 4: Create asset catalog files**

Create `ios/JLWLoader/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `ios/JLWLoader/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `ios/JLWLoader/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**Step 5: Create empty test file**

Create `ios/JLWLoaderTests/JLWLoaderTests.swift`:

```swift
import XCTest
@testable import JLWLoader

final class JLWLoaderTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

**Step 6: Generate Xcode project and verify build**

Run from `ios/` directory:
```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodegen generate
```
Expected: "Created project at JLWLoader.xcodeproj"

Then build:
```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add ios/
git commit -m "Scaffold iOS project with xcodegen"
```

---

### Task 2: Constants and Manifest model

**Files:**
- Create: `ios/JLWLoader/Constants.swift`
- Create: `ios/JLWLoader/Manifest.swift`
- Create: `ios/JLWLoaderTests/ManifestTests.swift`

**Step 1: Write failing test for Manifest decoding**

Create `ios/JLWLoaderTests/ManifestTests.swift`:

```swift
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
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD|error:)" | head -20
```
Expected: FAIL — `Manifest` type not found

**Step 3: Create Constants.swift**

Create `ios/JLWLoader/Constants.swift`:

```swift
import Foundation

enum Constants {
    static let apiBaseURL = "https://loader.jlwav.com"

    enum Keychain {
        static let apiKey = "com.jlwav.loader.apiKey"
        static let orgId = "com.jlwav.loader.orgId"
        static let service = "com.jlwav.loader"
    }

    enum UserDefaultsKeys {
        static let lastDownloadedAt = "lastDownloadedAt"
        static let lastDownloadedFilename = "lastDownloadedFilename"
        static let lastCheckedAt = "lastCheckedAt"
    }
}
```

**Step 4: Create Manifest.swift**

Create `ios/JLWLoader/Manifest.swift`:

```swift
import Foundation

struct Manifest: Codable {
    let orgId: String
    let packageFilename: String?
    let packageSizeBytes: Int?
    let packageChecksum: String?
    let uploadedAt: String?

    /// Message from worker when no package has been uploaded yet.
    let message: String?
    /// Legacy field — worker sends this for empty manifests.
    let version: String?

    init(
        orgId: String,
        packageFilename: String? = nil,
        packageSizeBytes: Int? = nil,
        packageChecksum: String? = nil,
        uploadedAt: String? = nil,
        message: String? = nil,
        version: String? = nil
    ) {
        self.orgId = orgId
        self.packageFilename = packageFilename
        self.packageSizeBytes = packageSizeBytes
        self.packageChecksum = packageChecksum
        self.uploadedAt = uploadedAt
        self.message = message
        self.version = version
    }

    /// Returns true if this manifest has a downloadable package.
    var hasPackage: Bool {
        packageFilename != nil && uploadedAt != nil
    }

    /// Extracts the hex hash from "sha256:abc123..." format.
    var sha256Value: String? {
        guard let checksum = packageChecksum,
              checksum.hasPrefix("sha256:") else { return nil }
        return String(checksum.dropFirst(7))
    }

    /// Formatted file size for display (e.g., "187.2 MB").
    var formattedSize: String? {
        guard let bytes = packageSizeBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
```

**Step 5: Run tests to verify they pass**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD)" | head -20
```
Expected: All tests PASS, BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios/JLWLoader/Constants.swift ios/JLWLoader/Manifest.swift ios/JLWLoaderTests/ManifestTests.swift
git commit -m "Add Constants and Manifest model with tests"
```

---

### Task 3: KeychainService

**Files:**
- Create: `ios/JLWLoader/KeychainService.swift`

**Step 1: Create KeychainService.swift**

Note: Keychain operations require a host app with entitlements — they can't be reliably unit tested in a simulator test bundle. We verify this works via the app's auth flow instead.

Create `ios/JLWLoader/KeychainService.swift`:

```swift
import Foundation
import Security

enum KeychainService {
    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case unexpectedData
    }

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Delete existing item first (update = delete + add)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Convenience: check if API key exists in Keychain.
    static var hasCredentials: Bool {
        read(key: Constants.Keychain.apiKey) != nil
    }

    /// Convenience: get stored API key.
    static var apiKey: String? {
        read(key: Constants.Keychain.apiKey)
    }

    /// Convenience: get stored org ID.
    static var orgId: String? {
        read(key: Constants.Keychain.orgId)
    }

    /// Save both API key and org ID after successful auth.
    static func saveCredentials(apiKey: String, orgId: String) throws {
        try save(key: Constants.Keychain.apiKey, value: apiKey)
        try save(key: Constants.Keychain.orgId, value: orgId)
    }

    /// Clear all stored credentials.
    static func clearCredentials() {
        delete(key: Constants.Keychain.apiKey)
        delete(key: Constants.Keychain.orgId)
    }
}
```

**Step 2: Verify build**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild build -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios/JLWLoader/KeychainService.swift
git commit -m "Add KeychainService with iCloud sync support"
```

---

### Task 4: APIClient

**Files:**
- Create: `ios/JLWLoader/APIClient.swift`
- Create: `ios/JLWLoaderTests/APIClientTests.swift`

**Step 1: Write failing tests**

Create `ios/JLWLoaderTests/APIClientTests.swift`:

```swift
import XCTest
@testable import JLWLoader

final class APIClientTests: XCTestCase {

    // MARK: - Auth response decoding

    func testDecodeAuthResponse() throws {
        let json = """
        { "apiKey": "key_abc123", "orgId": "jlw-aviation" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.apiKey, "key_abc123")
        XCTAssertEqual(response.orgId, "jlw-aviation")
    }

    // MARK: - Download response decoding

    func testDecodeDownloadResponse() throws {
        let json = """
        { "downloadUrl": "https://r2.example.com/file.zip", "filename": "update.zip", "expiresIn": 900 }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(DownloadResponse.self, from: json)
        XCTAssertEqual(response.downloadUrl, "https://r2.example.com/file.zip")
        XCTAssertEqual(response.filename, "update.zip")
    }

    // MARK: - API error decoding

    func testDecodeAPIError() throws {
        let json = """
        { "error": "Access code not recognized. Contact your administrator." }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIErrorResponse.self, from: json)
        XCTAssertEqual(response.error, "Access code not recognized. Contact your administrator.")
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD|error:)" | head -20
```
Expected: FAIL — types not found

**Step 3: Create APIClient.swift**

Create `ios/JLWLoader/APIClient.swift`:

```swift
import Foundation

// MARK: - Response types

struct AuthResponse: Codable {
    let apiKey: String
    let orgId: String
}

struct DownloadResponse: Codable {
    let downloadUrl: String
    let filename: String
    let expiresIn: Int
}

struct APIErrorResponse: Codable {
    let error: String
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case serverError(String)
    case networkError(Error)
    case decodingError
    case unauthorized
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .serverError(let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .decodingError:
            return "Unexpected response from server."
        case .unauthorized:
            return "Access code not recognized. Contact your administrator."
        case .noCredentials:
            return "No credentials found. Please re-enter your access code."
        }
    }
}

// MARK: - APIClient

struct APIClient {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = Constants.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Exchange access code for API key.
    /// POST /api/auth  { "accessCode": "JLW-7294" }
    func authenticate(accessCode: String) async throws -> AuthResponse {
        let body = ["accessCode": accessCode]
        return try await post("/api/auth", body: body, auth: .none)
    }

    /// Fetch current manifest for the authenticated org.
    /// GET /api/manifest  (X-API-Key header)
    func fetchManifest() async throws -> Manifest {
        guard let apiKey = KeychainService.apiKey else {
            throw APIError.noCredentials
        }
        return try await get("/api/manifest", auth: .apiKey(apiKey))
    }

    /// Get presigned download URL.
    /// POST /api/download  (X-API-Key header)
    func getDownloadURL() async throws -> DownloadResponse {
        guard let apiKey = KeychainService.apiKey else {
            throw APIError.noCredentials
        }
        let body: [String: String] = [:]
        return try await post("/api/download", body: body, auth: .apiKey(apiKey))
    }

    // MARK: - Private

    private enum Auth {
        case none
        case apiKey(String)
    }

    private func get<T: Decodable>(_ path: String, auth: Auth) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(auth, to: &request)

        return try await execute(request)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable, auth: Auth) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        applyAuth(auth, to: &request)

        return try await execute(request)
    }

    private func applyAuth(_ auth: Auth, to request: inout URLRequest) {
        switch auth {
        case .none:
            break
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.decodingError
        }

        if httpResponse.statusCode == 401 {
            // Try to extract error message
            if let errorResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIError.serverError(errorResp.error)
            }
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIError.serverError(errorResp.error)
            }
            throw APIError.serverError("Request failed (HTTP \(httpResponse.statusCode))")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError
        }
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD)" | head -20
```
Expected: All tests PASS, BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios/JLWLoader/APIClient.swift ios/JLWLoaderTests/APIClientTests.swift
git commit -m "Add APIClient with auth, manifest, and download endpoints"
```

---

### Task 5: DownloadManager

**Files:**
- Create: `ios/JLWLoader/DownloadManager.swift`
- Create: `ios/JLWLoaderTests/DownloadManagerTests.swift`

**Step 1: Write failing test for checksum verification**

Create `ios/JLWLoaderTests/DownloadManagerTests.swift`:

```swift
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
```

**Step 2: Run tests to verify they fail**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD|error:)" | head -20
```
Expected: FAIL — `DownloadManager` not found

**Step 3: Create DownloadManager.swift**

Create `ios/JLWLoader/DownloadManager.swift`:

```swift
import Foundation
import CryptoKit

actor DownloadManager {
    private let apiClient: APIClient
    private var downloadTask: URLSessionDataTask?

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    // MARK: - Public

    static let documentsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    /// Download the current update package with progress reporting.
    /// Returns the local file URL on success.
    func download(
        manifest: Manifest,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        // Get presigned download URL
        let downloadInfo = try await apiClient.getDownloadURL()

        guard let url = URL(string: downloadInfo.downloadUrl) else {
            throw DownloadError.invalidURL
        }

        // Delete any existing file first
        deleteExistingPackage()

        let filename = manifest.packageFilename ?? downloadInfo.filename
        let destinationURL = Self.documentsDirectory.appendingPathComponent(filename)

        // Download with progress
        let request = URLRequest(url: url)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.downloadFailed
        }

        let expectedLength = httpResponse.expectedContentLength
        var receivedData = Data()
        if expectedLength > 0 {
            receivedData.reserveCapacity(Int(expectedLength))
        }

        var receivedBytes: Int64 = 0
        for try await byte in asyncBytes {
            receivedData.append(byte)
            receivedBytes += 1
            if expectedLength > 0 && receivedBytes % 65536 == 0 {
                let progress = Double(receivedBytes) / Double(expectedLength)
                onProgress(min(progress, 1.0))
            }
        }
        onProgress(1.0)

        try receivedData.write(to: destinationURL)
        return destinationURL
    }

    /// Verify SHA-256 checksum of a downloaded file.
    func verify(fileURL: URL, expectedSHA256: String) throws -> Bool {
        let computedHash = try Self.computeSHA256(of: fileURL)
        return computedHash == expectedSHA256
    }

    /// Compute SHA-256 hash of a file.
    static func computeSHA256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Delete any previously downloaded package from Documents.
    func deleteExistingPackage() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: Self.documentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents where fileURL.pathExtension == "zip" {
            try? fm.removeItem(at: fileURL)
        }
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError {
        case invalidURL
        case downloadFailed
        case checksumMismatch
        case diskFull

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid download URL."
            case .downloadFailed:
                return "Download failed. Please try again."
            case .checksumMismatch:
                return "Download verification failed. The file may be corrupted."
            case .diskFull:
                return "Not enough storage on this device."
            }
        }
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD)" | head -20
```
Expected: All tests PASS, BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios/JLWLoader/DownloadManager.swift ios/JLWLoaderTests/DownloadManagerTests.swift
git commit -m "Add DownloadManager with download, checksum, and file management"
```

---

### Task 6: AppState

**Files:**
- Create: `ios/JLWLoader/AppState.swift`
- Create: `ios/JLWLoaderTests/AppStateTests.swift`

**Step 1: Write failing tests for state transitions**

Create `ios/JLWLoaderTests/AppStateTests.swift`:

```swift
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
```

**Step 2: Run tests to verify they fail**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD|error:)" | head -20
```
Expected: FAIL — `AppState` not found

**Step 3: Create AppState.swift**

Create `ios/JLWLoader/AppState.swift`:

```swift
import Foundation

enum UpdateStatus: Equatable {
    case checking
    case updateAvailable
    case downloading(progress: Double)
    case verifying
    case downloadComplete
    case upToDate
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var status: UpdateStatus = .checking
    @Published var manifest: Manifest?
    @Published var isAuthenticated: Bool = false

    private let apiClient: APIClient
    private let downloadManager: DownloadManager

    init(
        apiClient: APIClient = APIClient(),
        downloadManager: DownloadManager? = nil
    ) {
        self.apiClient = apiClient
        self.downloadManager = downloadManager ?? DownloadManager(apiClient: apiClient)
        self.isAuthenticated = KeychainService.hasCredentials
    }

    // MARK: - Auth

    func authenticate(accessCode: String) async throws {
        let response = try await apiClient.authenticate(accessCode: accessCode)
        try KeychainService.saveCredentials(apiKey: response.apiKey, orgId: response.orgId)
        isAuthenticated = true
    }

    // MARK: - Manifest

    func checkForUpdates() async {
        status = .checking
        do {
            let fetched = try await apiClient.fetchManifest()
            manifest = fetched
            UserDefaults.standard.set(
                ISO8601DateFormatter().string(from: Date()),
                forKey: Constants.UserDefaultsKeys.lastCheckedAt
            )
            let lastDownloaded = UserDefaults.standard.string(
                forKey: Constants.UserDefaultsKeys.lastDownloadedAt
            )
            status = Self.determineStatus(manifest: fetched, lastDownloadedAt: lastDownloaded)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Pure function for testability — determines status from manifest + last download.
    static func determineStatus(manifest: Manifest, lastDownloadedAt: String?) -> UpdateStatus {
        guard manifest.hasPackage, let uploadedAt = manifest.uploadedAt else {
            return .upToDate
        }

        guard let lastDownloaded = lastDownloadedAt else {
            return .updateAvailable
        }

        // Simple string comparison works for ISO8601 dates
        if uploadedAt > lastDownloaded {
            return .updateAvailable
        }
        return .upToDate
    }

    // MARK: - Download

    func downloadUpdate() async {
        guard let manifest = manifest else { return }

        status = .downloading(progress: 0)

        do {
            let fileURL = try await downloadManager.download(manifest: manifest) { [weak self] progress in
                Task { @MainActor in
                    self?.status = .downloading(progress: progress)
                }
            }

            // Verify checksum
            status = .verifying
            if let expectedHash = manifest.sha256Value {
                let valid = try await downloadManager.verify(
                    fileURL: fileURL,
                    expectedSHA256: expectedHash
                )
                if !valid {
                    // Auto-retry once
                    try? FileManager.default.removeItem(at: fileURL)
                    status = .downloading(progress: 0)
                    let retryURL = try await downloadManager.download(manifest: manifest) { [weak self] progress in
                        Task { @MainActor in
                            self?.status = .downloading(progress: progress)
                        }
                    }
                    status = .verifying
                    let retryValid = try await downloadManager.verify(
                        fileURL: retryURL,
                        expectedSHA256: expectedHash
                    )
                    if !retryValid {
                        try? FileManager.default.removeItem(at: retryURL)
                        status = .error("Download verification failed after retry. Please try again later.")
                        return
                    }
                }
            }

            // Success — record download
            UserDefaults.standard.set(
                ISO8601DateFormatter().string(from: Date()),
                forKey: Constants.UserDefaultsKeys.lastDownloadedAt
            )
            UserDefaults.standard.set(
                manifest.packageFilename,
                forKey: Constants.UserDefaultsKeys.lastDownloadedFilename
            )

            status = .downloadComplete

        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    var lastCheckedAt: String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastCheckedAt)
    }

    var lastDownloadedFilename: String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastDownloadedFilename)
    }

    var lastDownloadedAt: String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastDownloadedAt)
    }

    func formattedRelativeDate(_ iso: String?) -> String {
        guard let iso = iso,
              let date = ISO8601DateFormatter().date(from: iso) else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD)" | head -20
```
Expected: All tests PASS, BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios/JLWLoader/AppState.swift ios/JLWLoaderTests/AppStateTests.swift
git commit -m "Add AppState with status determination and download flow"
```

---

### Task 7: AccessCodeView

**Files:**
- Create: `ios/JLWLoader/AccessCodeView.swift`

**Step 1: Create AccessCodeView.swift**

Create `ios/JLWLoader/AccessCodeView.swift`:

```swift
import SwiftUI

struct AccessCodeView: View {
    @ObservedObject var appState: AppState
    @State private var accessCode = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("JLW Loader")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Enter your access code to get started.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                TextField("Access Code", text: $accessCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .disabled(isLoading)
                    .onSubmit { submit() }

                if let error = errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button(action: submit) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(accessCode.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }

            Spacer()

            Text("Contact your administrator if you need an access code.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
        }
        .padding()
    }

    private func submit() {
        let trimmed = accessCode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        errorMessage = nil
        isLoading = true

        Task {
            do {
                try await appState.authenticate(accessCode: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
```

**Step 2: Verify build**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild build -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios/JLWLoader/AccessCodeView.swift
git commit -m "Add AccessCodeView for first-launch auth flow"
```

---

### Task 8: MainView

**Files:**
- Create: `ios/JLWLoader/MainView.swift`

**Step 1: Create MainView.swift**

Create `ios/JLWLoader/MainView.swift`:

```swift
import SwiftUI

struct MainView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusContent
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("JLW Loader")
            .task {
                await appState.checkForUpdates()
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch appState.status {
        case .checking:
            checkingView
        case .updateAvailable:
            updateAvailableView
        case .downloading(let progress):
            downloadingView(progress: progress)
        case .verifying:
            verifyingView
        case .downloadComplete:
            downloadCompleteView
        case .upToDate:
            upToDateView
        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - State Views

    private var checkingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Checking for updates...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var updateAvailableView: some View {
        VStack(spacing: 16) {
            Spacer()

            Label("New Update Available", systemImage: "arrow.down.circle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            if let manifest = appState.manifest {
                VStack(spacing: 8) {
                    if let filename = manifest.packageFilename {
                        Text(filename)
                            .font(.body.monospaced())
                    }
                    if let uploadedAt = manifest.uploadedAt {
                        Text("Uploaded \(appState.formattedRelativeDate(uploadedAt))")
                            .foregroundColor(.secondary)
                    }
                    if let size = manifest.formattedSize {
                        Text("\(size) download")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button {
                Task { await appState.downloadUpdate() }
            } label: {
                Text("Download Update")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
            lastCheckedFooter
        }
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            Spacer()

            if let manifest = appState.manifest {
                Text("Downloading \(manifest.packageFilename ?? "update")...")
                    .font(.title3)
                    .fontWeight(.medium)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .padding(.horizontal)

            Text("\(Int(progress * 100))%")
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)

            if let manifest = appState.manifest, let totalBytes = manifest.packageSizeBytes {
                let downloaded = Int(Double(totalBytes) * progress)
                let formatter = ByteCountFormatter()
                Text("\(formatter.string(fromByteCount: Int64(downloaded))) of \(formatter.string(fromByteCount: Int64(totalBytes)))")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var verifyingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Verifying download...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var downloadCompleteView: some View {
        VStack(spacing: 16) {
            Spacer()

            Label("Download Complete", systemImage: "checkmark.circle.fill")
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
                Text("Verified ✓")
                    .foregroundColor(.green)
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

    private var upToDateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Label("Current", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            VStack(spacing: 8) {
                if let filename = appState.lastDownloadedFilename {
                    Text(filename)
                        .font(.body.monospaced())
                }
                if let downloadedAt = appState.lastDownloadedAt {
                    Text("Downloaded \(appState.formattedRelativeDate(downloadedAt))")
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
            lastCheckedFooter
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.orange)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await appState.checkForUpdates() }
            } label: {
                Text("Retry")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
            lastCheckedFooter
        }
    }

    // MARK: - Common

    private var lastCheckedFooter: some View {
        Group {
            if let lastChecked = appState.lastCheckedAt {
                Text("Last checked: \(appState.formattedRelativeDate(lastChecked))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}
```

**Step 2: Verify build**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild build -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios/JLWLoader/MainView.swift
git commit -m "Add MainView with all seven UI states"
```

---

### Task 9: Wire up JLWLoaderApp entry point

**Files:**
- Modify: `ios/JLWLoader/JLWLoaderApp.swift`

**Step 1: Update JLWLoaderApp.swift**

Replace contents of `ios/JLWLoader/JLWLoaderApp.swift`:

```swift
import SwiftUI

@main
struct JLWLoaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if appState.isAuthenticated {
                MainView(appState: appState)
            } else {
                AccessCodeView(appState: appState)
            }
        }
    }
}
```

**Step 2: Verify build**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild build -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED

**Step 3: Run all tests**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild test -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|BUILD)" | head -20
```
Expected: All tests PASS, BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/JLWLoader/JLWLoaderApp.swift
git commit -m "Wire up app entry point with auth routing"
```

---

### Task 10: Smoke test on simulator

**Files:** None — manual verification

**Step 1: Build and launch on simulator**

```bash
cd /Users/lwaddle/dev/jlw-loader/ios && xcodebuild build -project JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 2: Verify the following manually (or via screenshot)**

1. App launches to access code entry screen
2. Text field accepts input, Continue button enables
3. Entering an invalid code shows error message
4. Entering a valid code transitions to main screen
5. Main screen shows "Checking for updates..." then resolves to a status

**Step 3: Fix any issues found**

Address any build warnings, layout issues, or runtime errors.

**Step 4: Final commit**

```bash
git add -A ios/
git commit -m "iOS app Phase 1 complete — access code auth, manifest check, download with checksum"
```

---

## Task Summary

| Task | What it builds | Tests |
|------|---------------|-------|
| 1 | Xcode project scaffold via xcodegen | Placeholder |
| 2 | Constants + Manifest model | Decode, checksum extraction |
| 3 | KeychainService | Build-only (needs device for Keychain) |
| 4 | APIClient + response types | Response decoding |
| 5 | DownloadManager | SHA-256 computation |
| 6 | AppState | Status determination logic |
| 7 | AccessCodeView | Build-only (SwiftUI) |
| 8 | MainView (all 7 states) | Build-only (SwiftUI) |
| 9 | JLWLoaderApp entry point wiring | Full test suite run |
| 10 | Simulator smoke test | Manual verification |

## Notes for Phase 2

When picking up USB transfer, start a new design + plan cycle. The Phase 2 roadmap in the design doc (`docs/plans/2026-03-18-ios-app-phase1-design.md`) has scope, decisions, open questions, and expected file changes. New files: `USBTransferManager.swift`, `DocumentPickerView.swift`, plus updates to `MainView.swift` and `AppState.swift`.
