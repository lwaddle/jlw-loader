import Foundation

struct Manifest: Codable {
    let orgId: String
    let orgName: String?
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
        orgName: String? = nil,
        packageFilename: String? = nil,
        packageSizeBytes: Int? = nil,
        packageChecksum: String? = nil,
        uploadedAt: String? = nil,
        message: String? = nil,
        version: String? = nil
    ) {
        self.orgId = orgId
        self.orgName = orgName
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
