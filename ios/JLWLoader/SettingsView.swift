import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddAircraft = false
    @State private var showSignOutConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Aircraft") {
                    ForEach(appState.credentials) { cred in
                        Button {
                            if cred.orgId != appState.activeOrgId {
                                Task {
                                    await appState.switchOrg(to: cred.orgId)
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                Text(cred.orgName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if cred.orgId == appState.activeOrgId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteOrg)
                }

                Section("Support") {
                    Link(destination: URL(string: "https://lwaddle.github.io/jlw-loader/support")!) {
                        HStack {
                            Text("Support")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://lwaddle.github.io/jlw-loader/privacy")!) {
                        HStack {
                            Text("Privacy Policy")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Account") {
                    Button(role: .destructive) {
                        showSignOutConfirmation = true
                    } label: {
                        Text("Sign Out")
                    }
                }

                Section {
                } footer: {
                    HStack {
                        Spacer()
                        Text("JLW Loader v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
            .alert("Sign Out", isPresented: $showSignOutConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Sign Out", role: .destructive) {
                    appState.signOut()
                    dismiss()
                }
            } message: {
                Text("This will remove all aircraft and sign you out.")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddAircraft = true
                    } label: {
                        Label("Add Aircraft", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddAircraft) {
                AddAircraftView(appState: appState) {
                    showAddAircraft = false
                    dismiss()
                }
            }
        }
    }

    private func deleteOrg(at offsets: IndexSet) {
        for index in offsets {
            let cred = appState.credentials[index]
            appState.removeOrg(cred.orgId)
        }
        if !appState.isAuthenticated {
            dismiss()
        }
    }
}

struct AddAircraftView: View {
    @ObservedObject var appState: AppState
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var accessCode = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text("Add Aircraft")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Enter the access code for the aircraft.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    TextField("Access Code", text: $accessCode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .disabled(isLoading)
                        .onSubmit { submit() }

                    if let error = errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: submit) {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Add")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .disabled(accessCode.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }

                Spacer()
            }
            .frame(maxWidth: 500)
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        let trimmed = accessCode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        errorMessage = nil
        isLoading = true

        Task {
            do {
                try await appState.authenticate(accessCode: trimmed)
                onComplete()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
