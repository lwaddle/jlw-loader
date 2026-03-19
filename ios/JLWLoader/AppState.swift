import Foundation

enum UpdateStatus: Equatable {
    case checking
    case updateAvailable
    case downloading(progress: Double)
    case verifying
    case readyToTransfer
    case transferring(progress: Double, detail: String)
    case transferComplete(fileCount: Int)
    case upToDate
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var status: UpdateStatus = .checking
    @Published var manifest: Manifest?
    @Published var isAuthenticated: Bool = false
    @Published var showDocumentPicker: Bool = false

    private let apiClient: APIClient
    private let downloadManager: DownloadManager
    private let transferManager = USBTransferManager()
    private var downloadTask: Task<Void, Never>?

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
            let lastTransferred = UserDefaults.standard.string(
                forKey: Constants.UserDefaultsKeys.lastTransferredAt
            )
            // If a newer update was uploaded since our last download,
            // delete the stale local ZIP so the pilot sees "Update Available"
            // instead of "Ready to Transfer" with outdated data.
            if let uploadedAt = fetched.uploadedAt,
               let downloaded = lastDownloaded,
               uploadedAt > downloaded,
               hasLocalPackage() {
                await downloadManager.deleteExistingPackage()
            }

            status = Self.determineStatus(
                manifest: fetched,
                lastDownloadedAt: lastDownloaded,
                lastTransferredAt: lastTransferred,
                hasLocalPackage: hasLocalPackage()
            )
        } catch let error as APIError where error.isUnauthorized {
            // API key was revoked or invalid — clear credentials and
            // return to access code screen so pilot can re-enter.
            KeychainService.clearCredentials()
            isAuthenticated = false
        } catch {
            status = .error(error.localizedDescription)
        }
    }

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

        // Already transferred this (or newer) upload
        if let transferred = lastTransferredAt, uploadedAt <= transferred {
            return .upToDate
        }

        // Downloaded but not yet transferred
        if hasLocalPackage, let downloaded = lastDownloadedAt {
            let notYetTransferred = lastTransferredAt == nil || downloaded > (lastTransferredAt ?? "")
            if notYetTransferred && downloaded >= uploadedAt {
                return .readyToTransfer
            }
        }

        return .updateAvailable
    }

    // MARK: - Download

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if let manifest = manifest {
            status = Self.determineStatus(
                manifest: manifest,
                lastDownloadedAt: UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastDownloadedAt),
                lastTransferredAt: UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastTransferredAt),
                hasLocalPackage: hasLocalPackage()
            )
        } else {
            status = .upToDate
        }
    }

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

            status = .readyToTransfer

        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Transfer

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

    var lastTransferredAt: String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastTransferredAt)
    }

    var lastTransferredFilename: String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastTransferredFilename)
    }

    /// Check whether a downloaded .zip package exists in Documents.
    private func hasLocalPackage() -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: DownloadManager.documentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.pathExtension == "zip" }
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
