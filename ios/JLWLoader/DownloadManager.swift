import Foundation
import CryptoKit

actor DownloadManager {
    private let apiClient: APIClient

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
