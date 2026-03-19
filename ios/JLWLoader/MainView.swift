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
        case .readyToTransfer:
            readyToTransferView
        case .transferring(let progress, let detail):
            transferringView(progress: progress, detail: detail)
        case .transferComplete(let fileCount):
            transferCompleteView(fileCount: fileCount)
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

            Button {
                appState.cancelDownload()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

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
