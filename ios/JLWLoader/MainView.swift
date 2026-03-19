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
