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
        static let lastTransferredAt = "lastTransferredAt"
        static let lastTransferredFilename = "lastTransferredFilename"
    }
}
