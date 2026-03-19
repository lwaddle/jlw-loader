# iOS Multi-Org Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow pilots to add multiple access codes and switch between aircraft/orgs in the iOS app.

**Architecture:** Store multiple credential sets in Keychain as a JSON array. Add a Settings view for org management (add, remove, switch). APIClient reads credentials from AppState instead of directly from Keychain. Backend adds `orgName` to auth response.

**Tech Stack:** Swift, SwiftUI, iOS Keychain (Security framework), Cloudflare Worker (TypeScript)

---

### Task 1: Add orgName to backend auth response

**Files:**
- Modify: `worker/src/types.ts:38-41` (AccessCodeEntry interface)
- Modify: `worker/src/auth.ts:58-78` (createAccessCode function)
- Modify: `worker/src/index.ts:123-145` (handleAuth function)

**Step 1: Add orgName to AccessCodeEntry type**

In `worker/src/types.ts`, update the `AccessCodeEntry` interface:

```typescript
export interface AccessCodeEntry {
  orgId: string;
  apiKey: string;
  orgName?: string;
}
```

**Step 2: Store orgName when creating access codes**

In `worker/src/index.ts`, the `handleCreateAccessCode` function has access to the admin's Clerk JWT. We need to pass the org name from the admin context. Update `handleCreateAccessCode` at line 303:

```typescript
async function handleCreateAccessCode(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  let body: { accessCode?: string };
  try {
    body = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  const accessCode = body.accessCode?.trim();
  if (!accessCode) {
    return errorResponse('accessCode is required', 400);
  }
  if (accessCode.length > 20) {
    return errorResponse('accessCode must be 20 characters or less', 400);
  }

  try {
    await createAccessCode(env.ACCESS_CODES_KV, admin.orgId, accessCode, admin.orgName);
    return json({ accessCode }, 201);
  } catch (err) {
    if (err instanceof Error && err.message === 'ACCESS_CODE_EXISTS') {
      return errorResponse('This access code is unavailable. Please choose a different one.', 409);
    }
    throw err;
  }
}
```

Update `authenticateAdmin` to also return orgName. The Clerk JWT v5 has abbreviated claims — org name is at `o.nam` (check `worker/src/clerk.ts` for the claims structure). Update the return type and value:

```typescript
async function authenticateAdmin(
  request: Request,
  env: Env,
): Promise<{ orgId: string; userId: string; orgName: string } | null> {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return null;

  const token = authHeader.slice(7);
  const claims = await verifyClerkToken(token, env);
  if (!claims) return null;

  return { orgId: claims.org_slug, userId: claims.sub, orgName: claims.org_name || claims.org_slug };
}
```

Check `worker/src/clerk.ts` for how claims are parsed — the v5 abbreviated claims use `o.slg` for slug. The org name may be at `o.nam` or similar. If it's not in the JWT, fall back to the org slug. Update the ClerkClaims type in clerk.ts if needed to include `org_name`.

**Step 3: Update createAccessCode to accept orgName**

In `worker/src/auth.ts`, update the function signature and entry creation:

```typescript
export async function createAccessCode(
  kv: KVNamespace,
  orgId: string,
  accessCode: string,
  orgName?: string,
): Promise<string> {
  const existing = await kv.get(`code:${accessCode}`);
  if (existing !== null) {
    throw new Error('ACCESS_CODE_EXISTS');
  }

  const apiKey = generateApiKey();
  const entry: AccessCodeEntry = { orgId, apiKey, orgName };

  await kv.put(`code:${accessCode}`, JSON.stringify(entry));

  const codes = await listAccessCodes(kv, orgId);
  codes.push(accessCode);
  await saveOrgIndex(kv, orgId, codes);

  return apiKey;
}
```

**Step 4: Return orgName in auth response**

In `worker/src/index.ts`, update `handleAuth` at line 144:

```typescript
return json({ apiKey: entry.apiKey, orgId: entry.orgId, orgName: entry.orgName || entry.orgId });
```

**Step 5: Build and verify**

Run: `cd worker && npm run build`
Expected: No TypeScript errors

**Step 6: Commit**

```bash
git add worker/src/types.ts worker/src/auth.ts worker/src/index.ts worker/src/clerk.ts
git commit -m "feat: add orgName to access code entries and auth response"
```

---

### Task 2: Create OrgCredential model and update KeychainService

**Files:**
- Create: `ios/JLWLoader/OrgCredential.swift`
- Modify: `ios/JLWLoader/KeychainService.swift`
- Modify: `ios/JLWLoader/Constants.swift:6-9`

**Step 1: Write tests for OrgCredential encoding/decoding**

Add to `ios/JLWLoaderTests/OrgCredentialTests.swift`:

```swift
import XCTest
@testable import JLWLoader

final class OrgCredentialTests: XCTestCase {

    func testEncodeDecode() throws {
        let cred = OrgCredential(orgId: "jlw-aviation", orgName: "JLW Aviation", apiKey: "key_abc123")
        let data = try JSONEncoder().encode(cred)
        let decoded = try JSONDecoder().decode(OrgCredential.self, from: data)
        XCTAssertEqual(decoded.orgId, "jlw-aviation")
        XCTAssertEqual(decoded.orgName, "JLW Aviation")
        XCTAssertEqual(decoded.apiKey, "key_abc123")
    }

    func testDecodeWithoutOrgName() throws {
        let json = """
        { "orgId": "jlw-aviation", "apiKey": "key_abc123" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OrgCredential.self, from: json)
        XCTAssertEqual(decoded.orgId, "jlw-aviation")
        XCTAssertEqual(decoded.orgName, "jlw-aviation")
        XCTAssertEqual(decoded.apiKey, "key_abc123")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/OrgCredentialTests 2>&1 | tail -20`
Expected: FAIL — OrgCredential not defined

**Step 3: Create OrgCredential model**

Create `ios/JLWLoader/OrgCredential.swift`:

```swift
import Foundation

struct OrgCredential: Codable, Identifiable, Equatable {
    let orgId: String
    let orgName: String
    let apiKey: String

    var id: String { orgId }

    init(orgId: String, orgName: String, apiKey: String) {
        self.orgId = orgId
        self.orgName = orgName
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orgId = try container.decode(String.self, forKey: .orgId)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName) ?? orgId
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JLWLoaderTests/OrgCredentialTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Update Constants with new Keychain keys**

In `ios/JLWLoader/Constants.swift`, add new keys to the Keychain enum:

```swift
enum Keychain {
    static let apiKey = "com.jlwav.loader.apiKey"
    static let orgId = "com.jlwav.loader.orgId"
    static let service = "com.jlwav.loader"
    static let credentials = "com.jlwav.loader.credentials"
    static let activeOrgId = "com.jlwav.loader.activeOrgId"
}
```

**Step 6: Add multi-credential methods to KeychainService**

In `ios/JLWLoader/KeychainService.swift`, add these methods after the existing convenience methods (after line 97):

```swift
// MARK: - Multi-org credential management

/// Load all stored org credentials.
static func loadCredentials() -> [OrgCredential] {
    guard let json = read(key: Constants.Keychain.credentials),
          let data = json.data(using: .utf8),
          let creds = try? JSONDecoder().decode([OrgCredential].self, from: data) else {
        return []
    }
    return creds
}

/// Save all org credentials.
static func saveCredentials(_ credentials: [OrgCredential]) throws {
    let data = try JSONEncoder().encode(credentials)
    guard let json = String(data: data, encoding: .utf8) else {
        throw KeychainError.unexpectedData
    }
    try save(key: Constants.Keychain.credentials, value: json)
}

/// Get the active org ID.
static var activeOrgId: String? {
    read(key: Constants.Keychain.activeOrgId)
}

/// Set the active org ID.
static func setActiveOrgId(_ orgId: String) throws {
    try save(key: Constants.Keychain.activeOrgId, value: orgId)
}

/// Migrate from single-credential format to multi-credential format.
/// Returns true if migration was performed.
@discardableResult
static func migrateIfNeeded() -> Bool {
    // Already migrated if credentials key exists
    if read(key: Constants.Keychain.credentials) != nil {
        return false
    }

    // Check for old single-credential keys
    guard let oldApiKey = read(key: Constants.Keychain.apiKey),
          let oldOrgId = read(key: Constants.Keychain.orgId) else {
        return false
    }

    // Migrate: wrap old credentials into array format
    let cred = OrgCredential(orgId: oldOrgId, orgName: oldOrgId, apiKey: oldApiKey)
    do {
        try saveCredentials([cred])
        try setActiveOrgId(oldOrgId)
        // Delete old keys
        delete(key: Constants.Keychain.apiKey)
        delete(key: Constants.Keychain.orgId)
        return true
    } catch {
        return false
    }
}
```

**Step 7: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 8: Commit**

```bash
git add ios/JLWLoader/OrgCredential.swift ios/JLWLoader/KeychainService.swift ios/JLWLoader/Constants.swift ios/JLWLoaderTests/OrgCredentialTests.swift
git commit -m "feat: add OrgCredential model and multi-credential Keychain support"
```

---

### Task 3: Update AuthResponse and APIClient for multi-org

**Files:**
- Modify: `ios/JLWLoader/APIClient.swift:5-8` (AuthResponse struct)
- Modify: `ios/JLWLoader/APIClient.swift:57-64` (APIClient struct)
- Modify: `ios/JLWLoaderTests/APIClientTests.swift`

**Step 1: Write test for AuthResponse with orgName**

Add to `ios/JLWLoaderTests/APIClientTests.swift`:

```swift
func testDecodeAuthResponseWithOrgName() throws {
    let json = """
    { "apiKey": "key_abc123", "orgId": "jlw-aviation", "orgName": "JLW Aviation" }
    """.data(using: .utf8)!

    let response = try JSONDecoder().decode(AuthResponse.self, from: json)
    XCTAssertEqual(response.apiKey, "key_abc123")
    XCTAssertEqual(response.orgId, "jlw-aviation")
    XCTAssertEqual(response.orgName, "JLW Aviation")
}

func testDecodeAuthResponseWithoutOrgName() throws {
    let json = """
    { "apiKey": "key_abc123", "orgId": "jlw-aviation" }
    """.data(using: .utf8)!

    let response = try JSONDecoder().decode(AuthResponse.self, from: json)
    XCTAssertEqual(response.orgName, "jlw-aviation")
}
```

**Step 2: Update AuthResponse**

In `ios/JLWLoader/APIClient.swift`, update the struct:

```swift
struct AuthResponse: Codable {
    let apiKey: String
    let orgId: String
    let orgName: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        orgId = try container.decode(String.self, forKey: .orgId)
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName) ?? orgId
    }
}
```

**Step 3: Update APIClient to accept apiKey parameter instead of reading Keychain**

Currently `fetchManifest()` and `getDownloadURL()` read `KeychainService.apiKey` directly. Change them to accept an apiKey parameter so AppState can pass the active credential's key:

```swift
struct APIClient {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = Constants.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func authenticate(accessCode: String) async throws -> AuthResponse {
        let body = ["accessCode": accessCode]
        return try await post("/api/auth", body: body, auth: .none)
    }

    func fetchManifest(apiKey: String) async throws -> Manifest {
        return try await get("/api/manifest", auth: .apiKey(apiKey))
    }

    func getDownloadURL(apiKey: String) async throws -> DownloadResponse {
        let body: [String: String] = [:]
        return try await post("/api/download", body: body, auth: .apiKey(apiKey))
    }

    // ... private methods remain unchanged
}
```

**Step 4: Update all call sites in AppState**

Every place in `AppState.swift` that calls `apiClient.fetchManifest()` or `apiClient.getDownloadURL()` needs to pass the active API key. This will be done in Task 5 when we refactor AppState. For now, add a temporary backward-compatible overload to avoid breaking the build:

```swift
func fetchManifest() async throws -> Manifest {
    guard let apiKey = KeychainService.apiKey ?? KeychainService.loadCredentials().first?.apiKey else {
        throw APIError.noCredentials
    }
    return try await fetchManifest(apiKey: apiKey)
}

func getDownloadURL() async throws -> DownloadResponse {
    guard let apiKey = KeychainService.apiKey ?? KeychainService.loadCredentials().first?.apiKey else {
        throw APIError.noCredentials
    }
    return try await getDownloadURL(apiKey: apiKey)
}
```

**Step 5: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add ios/JLWLoader/APIClient.swift ios/JLWLoaderTests/APIClientTests.swift
git commit -m "feat: add orgName to AuthResponse and parameterize APIClient auth"
```

---

### Task 4: Refactor AppState for multi-org

**Files:**
- Modify: `ios/JLWLoader/AppState.swift`

**Step 1: Add credential state and org management methods**

Add published properties and methods to `AppState`. Replace the current init, authenticate, and checkForUpdates with multi-org-aware versions:

```swift
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

    /// The currently active credential, derived from credentials + activeOrgId.
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

        try KeychainService.saveCredentials(credentials)
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
        await deleteLocalPackageIfExists()
        await checkForUpdates()
    }

    func removeOrg(_ orgId: String) {
        credentials.removeAll { $0.orgId == orgId }
        try? KeychainService.saveCredentials(credentials)

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

    private func deleteLocalPackageIfExists() async {
        if hasLocalPackage() {
            await downloadManager.deleteExistingPackage()
        }
    }
```

**Step 2: Update checkForUpdates to use activeCredential**

Replace the existing `checkForUpdates()`:

```swift
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
        // Only clear this credential, not all
        removeOrg(cred.orgId)
    } catch {
        status = .error(error.localizedDescription)
    }
}
```

**Step 3: Update downloadUpdate to use activeCredential**

In the existing `downloadUpdate()` method, replace the `apiClient.getDownloadURL()` call to pass the API key:

Find:
```swift
let urlResp = try await ...
```

The download manager uses APIClient internally. We need to update DownloadManager to also accept an apiKey. For now, since DownloadManager calls `apiClient.getDownloadURL()`, update the download call. Check `DownloadManager.swift` — if it calls `apiClient.getDownloadURL()` internally, it also needs the apiKey parameter. Update accordingly.

**Step 4: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add ios/JLWLoader/AppState.swift
git commit -m "feat: refactor AppState for multi-org credential management"
```

---

### Task 5: Update DownloadManager to accept apiKey

**Files:**
- Modify: `ios/JLWLoader/DownloadManager.swift`
- Modify: `ios/JLWLoader/AppState.swift` (download call sites)

**Step 1: Read DownloadManager.swift to understand the current flow**

Read the file to see how it calls `apiClient.getDownloadURL()`. The manager likely stores a reference to APIClient and calls it internally.

**Step 2: Update DownloadManager.download() to accept apiKey**

Add an `apiKey` parameter to the `download` method. Pass it through to `apiClient.getDownloadURL(apiKey:)`.

**Step 3: Update AppState.downloadUpdate() to pass activeCredential.apiKey**

In `AppState.downloadUpdate()`, pass `activeCredential?.apiKey` to the download manager call.

**Step 4: Remove backward-compatible overloads from APIClient**

Remove the no-argument `fetchManifest()` and `getDownloadURL()` methods added in Task 3 Step 4, since all call sites now pass apiKey explicitly.

**Step 5: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add ios/JLWLoader/DownloadManager.swift ios/JLWLoader/AppState.swift ios/JLWLoader/APIClient.swift
git commit -m "feat: pass apiKey through DownloadManager for multi-org support"
```

---

### Task 6: Create SettingsView

**Files:**
- Create: `ios/JLWLoader/SettingsView.swift`

**Step 1: Build the Settings view**

Create `ios/JLWLoader/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddAircraft = false

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
```

**Step 2: Create AddAircraftView**

This is a simplified version of AccessCodeView that adds a new org credential. Add to the same file or create a separate file:

```swift
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
```

**Step 3: Commit**

```bash
git add ios/JLWLoader/SettingsView.swift
git commit -m "feat: add Settings view with aircraft management"
```

---

### Task 7: Add Settings gear icon to MainView

**Files:**
- Modify: `ios/JLWLoader/MainView.swift:6-31`

**Step 1: Add settings sheet state and toolbar button**

In `MainView.swift`, add a `@State private var showSettings = false` property and a toolbar item with a gear icon. The gear should only be visible when `appState.canAccessSettings` is true.

Update the NavigationStack content:

```swift
struct MainView: View {
    @ObservedObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusContent
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
                        Task { await appState.transferToUSB(driveURL: url) }
                    },
                    onCancel: {
                        appState.showDocumentPicker = false
                    }
                )
            }
        }
    }
    // ... rest of view unchanged
}
```

Note: The nav title changes from the static "JLW Loader" to the active org name — this gives the pilot constant visibility of which aircraft they're working with.

**Step 2: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add ios/JLWLoader/MainView.swift
git commit -m "feat: add settings gear icon and org name in nav title"
```

---

### Task 8: Handle first-launch and migration flow

**Files:**
- Modify: `ios/JLWLoader/JLWLoaderApp.swift`
- Modify: `ios/JLWLoader/AppState.swift` (init already handles migration)

**Step 1: Verify the app entry point handles both flows**

The current `JLWLoaderApp.swift` checks `appState.isAuthenticated` to decide between `AccessCodeView` and `MainView`. After migration, `isAuthenticated` is set based on whether `credentials` is non-empty. This should work as-is.

Verify that the `AccessCodeView` still works for first-time users (no credentials, no migration needed). The authenticate flow in AppState now appends to the credentials array and sets activeOrgId, which is correct for first launch.

**Step 2: Build and run on simulator**

Run: `xcodebuild build -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit (if any changes needed)**

```bash
git add ios/JLWLoader/JLWLoaderApp.swift
git commit -m "feat: verify migration and first-launch flow"
```

---

### Task 9: Clean up deprecated Keychain methods

**Files:**
- Modify: `ios/JLWLoader/KeychainService.swift`

**Step 1: Remove old single-credential convenience methods**

The old `hasCredentials`, `apiKey`, `orgId`, `saveCredentials(apiKey:orgId:)`, and `clearCredentials()` methods are no longer used after all call sites have been updated. Remove them from KeychainService:

Remove lines 72-97 (the old convenience methods). Keep the core `save`, `read`, `delete` methods and the new multi-credential methods.

**Step 2: Verify no remaining references to old methods**

Search the codebase for `KeychainService.apiKey`, `KeychainService.orgId`, `KeychainService.hasCredentials`, `KeychainService.saveCredentials(apiKey:`, and `KeychainService.clearCredentials()`. All should be gone or updated.

**Step 3: Run all tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add ios/JLWLoader/KeychainService.swift
git commit -m "chore: remove deprecated single-credential Keychain methods"
```
