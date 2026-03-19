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
        apiKey: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        // Get presigned download URL
        let downloadInfo = try await apiClient.getDownloadURL(apiKey: apiKey)

        guard let url = URL(string: downloadInfo.downloadUrl) else {
            throw DownloadError.invalidURL
        }

        // Delete any existing file first
        deleteExistingPackage()

        let filename = manifest.packageFilename ?? downloadInfo.filename
        let destinationURL = Self.documentsDirectory.appendingPathComponent(filename)

        // Use delegate-based download for progress reporting.
        // URLSession.download(for:) (async/await) does NOT call delegate progress methods.
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let request = URLRequest(url: url)

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let task = session.downloadTask(with: request)
            task.resume()
        }

        onProgress(1.0)

        // Move temp file to Documents
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return destinationURL
    }

    /// Verify SHA-256 checksum of a downloaded file.
    func verify(fileURL: URL, expectedSHA256: String) throws -> Bool {
        let computedHash = try Self.computeSHA256(of: fileURL)
        return computedHash == expectedSHA256
    }

    /// Compute SHA-256 hash of a file, streaming in chunks to avoid loading entire file into memory.
    static func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB chunks
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: bufferSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
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

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void
    // Nonisolated(unsafe) because the continuation is set once before the task starts
    // and consumed once when the task completes — no concurrent access.
    nonisolated(unsafe) var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @Sendable @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(progress, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy to a temp location we control (URLSession deletes the original after this returns)
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
            continuation?.resume(returning: tempCopy)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
