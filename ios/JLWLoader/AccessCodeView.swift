import SwiftUI

struct AccessCodeView: View {
    @ObservedObject var appState: AppState
    @State private var accessCode = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("JLW Loader")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Enter your access code to get started.")
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
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(accessCode.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)

            }

            Spacer()

            Text("Contact your administrator if you need an access code.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: 500)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func submit() {
        let trimmed = accessCode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        errorMessage = nil
        isLoading = true

        Task {
            do {
                try await appState.authenticate(accessCode: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
