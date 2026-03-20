import SwiftUI

struct MainView: View {
    @ObservedObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusContent
            }
            .alert("No New Updates", isPresented: $appState.showNoUpdateAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your software is up to date.")
            }
            .frame(maxWidth: 500)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(appState.activeOrgName ?? "JLW Loader")
            .toolbar {
                if appState.canAccessSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .task {
                await appState.checkForUpdates()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(appState: appState)
            }
            .sheet(isPresented: $appState.showDocumentPicker) {
                DocumentPickerView(
                    onPick: { url in
                        appState.showDocumentPicker = false
                        appState.confirmErase(driveURL: url)
                    },
                    onCancel: {
                        appState.showDocumentPicker = false
                    }
                )
            }
            .alert("Erase USB Drive?", isPresented: $appState.showEraseConfirmation) {
                Button("Cancel", role: .cancel) {
                    appState.cancelErase()
                }
                Button("Erase & Transfer", role: .destructive) {
                    if let url = appState.pendingDriveURL {
                        appState.pendingDriveURL = nil
                        Task { await appState.transferToUSB(driveURL: url) }
                    }
                }
            } message: {
                if let url = appState.pendingDriveURL {
                    Text("All data on \(appState.driveName(for: url)) will be permanently erased and replaced with the database update.")
                }
            }
            .onChange(of: appState.showEraseConfirmation) { showing in
                if !showing {
                    appState.pendingDriveURL = nil
                }
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
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Checking for updates...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var updateAvailableView: some View {
        VStack(spacing: 24) {
            Spacer()

            Label("New Update Available", systemImage: "arrow.down.circle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            if let manifest = appState.manifest {
                VStack(spacing: 12) {
                    if let uploadedAt = manifest.uploadedAt {
                        Text("Updated \(appState.formattedRelativeDate(uploadedAt))")
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
        VStack(spacing: 24) {
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
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Verifying download...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var readyToTransferView: some View {
        VStack(spacing: 24) {
            Spacer()

            Label("Ready to Transfer", systemImage: "arrow.down.circle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.blue)

            VStack(spacing: 12) {
                Text("Downloaded")
                    .foregroundColor(.secondary)
                Text("Verified \u{2713}")
                    .foregroundColor(.green)
            }

            Text("Connect USB drive\nusing your USB-C to USB-A adapter")
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
    }

    private var upToDateView: some View {
        VStack(spacing: 24) {
            Spacer()

            Label("Current", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            VStack(spacing: 12) {
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

            if appState.hasLocalPackage() {
                Button {
                    appState.showDocumentPicker = true
                } label: {
                    Text("Transfer Again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    private func transferringView(progress: Double, detail: String) -> some View {
        VStack(spacing: 24) {
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
        VStack(spacing: 24) {
            Spacer()

            Label("Transfer Complete", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            Text("\(fileCount) files written")
                .font(.body)

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

            Button {
                appState.showDocumentPicker = true
            } label: {
                Text("Transfer to Another Drive")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
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
