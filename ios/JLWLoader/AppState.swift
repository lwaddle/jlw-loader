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
    @Published var credentials: [OrgCredential] = []
    @Published var activeOrgId: String?

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

        // Migrate single-credential format if needed
        KeychainService.migrateIfNeeded()

        // Load credentials
        self.credentials = KeychainService.loadCredentials()
        self.activeOrgId = KeychainService.activeOrgId
        self.isAuthenticated = !credentials.isEmpty
    }

    /// The currently active credential.
    var activeCredential: OrgCredential? {
        guard let activeId = activeOrgId else {
            return credentials.first
        }
        return credentials.first { $0.orgId == activeId } ?? credentials.first
    }

    /// The display name of the active org.
    var activeOrgName: String? {
        activeCredential?.orgName
    }

    /// Whether the app is in an idle state where settings can be accessed.
    var canAccessSettings: Bool {
        switch status {
        case .upToDate, .updateAvailable, .error, .readyToTransfer:
            return true
        default:
            return false
        }
    }

    // MARK: - Auth

    func authenticate(accessCode: String) async throws {
        let response = try await apiClient.authenticate(accessCode: accessCode)

        // Check for duplicate org
        if credentials.contains(where: { $0.orgId == response.orgId }) {
            throw APIError.serverError("This aircraft is already added.")
        }

        let cred = OrgCredential(orgId: response.orgId, orgName: response.orgName, apiKey: response.apiKey)
        credentials.append(cred)
        activeOrgId = response.orgId

        try KeychainService.saveAllCredentials(credentials)
        try KeychainService.setActiveOrgId(response.orgId)
        isAuthenticated = true
    }

    // MARK: - Org Switching

    func switchOrg(to orgId: String) async {
        guard orgId != activeOrgId,
              credentials.contains(where: { $0.orgId == orgId }) else { return }

        activeOrgId = orgId
        try? KeychainService.setActiveOrgId(orgId)

        // Clear current state and check for updates with new org
        manifest = nil
        cancelDownload()
        if hasLocalPackage() {
            await downloadManager.deleteExistingPackage()
        }
        await checkForUpdates()
    }

    func removeOrg(_ orgId: String) {
        credentials.removeAll { $0.orgId == orgId }
        try? KeychainService.saveAllCredentials(credentials)

        if credentials.isEmpty {
            activeOrgId = nil
            KeychainService.delete(key: Constants.Keychain.activeOrgId)
            isAuthenticated = false
            return
        }

        if activeOrgId == orgId {
            activeOrgId = credentials.first?.orgId
            if let newActive = activeOrgId {
                try? KeychainService.setActiveOrgId(newActive)
            }
        }
    }

    // MARK: - Manifest

    func checkForUpdates() async {
        guard let cred = activeCredential else {
            status = .error("No active aircraft selected.")
            return
        }

        status = .checking
        do {
            let fetched = try await apiClient.fetchManifest(apiKey: cred.apiKey)
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
            removeOrg(cred.orgId)
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
        guard let apiKey = activeCredential?.apiKey else {
            status = .error("No active aircraft selected.")
            return
        }

        status = .downloading(progress: 0)

        do {
            let fileURL = try await downloadManager.download(manifest: manifest, apiKey: apiKey) { [weak self] progress in
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
                    let retryURL = try await downloadManager.download(manifest: manifest, apiKey: apiKey) { [weak self] progress in
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

        // Verify the selected location is an external/removable drive
        if let resourceValues = try? driveURL.resourceValues(
            forKeys: [.volumeURLKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        ) {
            let isRemovable = resourceValues.volumeIsRemovable ?? false
            let isInternal = resourceValues.volumeIsInternal ?? true
            if !isRemovable && isInternal {
                status = .error("Please select a connected USB drive, not internal storage like iCloud or On My iPad.")
                return
            }

            // Verify the user selected the drive root, not a subfolder within it
            if let volumeURL = resourceValues.volume,
               driveURL.standardizedFileURL != volumeURL.standardizedFileURL {
                status = .error("Please select the USB drive itself, not a folder within it. In the file picker, tap the drive name and then tap Open.")
                return
            }
        }

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
    func hasLocalPackage() -> Bool {
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
