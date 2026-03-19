import Foundation

// MARK: - USBTransferManager

actor USBTransferManager {

    // MARK: - Errors

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
                formatter.countStyle = .file
                let neededStr = formatter.string(fromByteCount: needed)
                let availableStr = formatter.string(fromByteCount: available)
                return "Not enough space on the drive. \(neededStr) needed but only \(availableStr) available."

            case .wipeFailed(let detail):
                return "Failed to clear drive contents. \(detail)"

            case .extractionFailed(let detail):
                return "Transfer failed. Do not use this drive for the update. Reconnect the drive and try again. (\(detail))"

            case .driveDisconnected:
                return "Drive was disconnected during transfer. Reconnect the drive and try again."
            }
        }
    }

    // MARK: - Public API

    /// Recursively deletes all contents of a directory, preserving the directory itself.
    func wipeDrive(at url: URL) throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw TransferError.driveNotAccessible
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch {
            throw TransferError.wipeFailed(error.localizedDescription)
        }

        for itemURL in contents {
            do {
                try fm.removeItem(at: itemURL)
            } catch {
                throw TransferError.wipeFailed(
                    "Could not remove \(itemURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        // Verify drive is empty
        let remaining = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        if !remaining.isEmpty {
            throw TransferError.wipeFailed("Drive still contains \(remaining.count) item(s) after wipe.")
        }
    }

    /// Checks if the drive at the given URL has enough free space.
    func checkDriveSpace(at url: URL, requiredBytes: Int64) throws -> Bool {
        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        } catch {
            throw TransferError.driveNotAccessible
        }

        guard let available = resourceValues.volumeAvailableCapacity else {
            throw TransferError.driveNotAccessible
        }

        return Int64(available) >= requiredBytes
    }

    /// Full transfer flow: check space, wipe drive, extract ZIP, report progress.
    func transfer(
        zipAt source: URL,
        to destination: URL,
        requiredBytes: Int64,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> Int {
        // Check space
        let hasSpace = try checkDriveSpace(at: destination, requiredBytes: requiredBytes)
        if !hasSpace {
            let resourceValues = try destination.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            let available = Int64(resourceValues.volumeAvailableCapacity ?? 0)
            throw TransferError.insufficientSpace(needed: requiredBytes, available: available)
        }

        // Wipe drive
        onProgress(0.0, "Clearing drive contents...")
        try wipeDrive(at: destination)

        // Extract ZIP — map ZIPExtractor progress (file N of total) to 5%–100%
        let fileCount: Int
        do {
            fileCount = try await ZIPExtractor.extract(
                zipAt: source,
                to: destination
            ) { extracted, total in
                let fraction = total > 0 ? Double(extracted) / Double(total) : 1.0
                let progress = 0.05 + fraction * 0.95
                onProgress(progress, "Writing files... \(extracted) of \(total)")
            }
        } catch {
            // Check if drive disappeared
            if !FileManager.default.fileExists(atPath: destination.path) {
                throw TransferError.driveDisconnected
            }
            throw TransferError.extractionFailed(error.localizedDescription)
        }

        // Final check that drive is still there
        if !FileManager.default.fileExists(atPath: destination.path) {
            throw TransferError.driveDisconnected
        }

        return fileCount
    }
}
