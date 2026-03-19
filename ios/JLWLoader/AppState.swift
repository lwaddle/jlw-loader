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
            status = Self.determineStatus(manifest: fetched, lastDownloadedAt: lastDownloaded)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Pure function for testability — determines status from manifest + last download.
    nonisolated static func determineStatus(manifest: Manifest, lastDownloadedAt: String?) -> UpdateStatus {
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

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if let manifest = manifest {
            status = Self.determineStatus(
                manifest: manifest,
                lastDownloadedAt: UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.lastDownloadedAt)
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
