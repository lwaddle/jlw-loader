# Settings View Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure SettingsView from a single-section aircraft manager into a grouped settings screen with support links, sign-out, and version info.

**Architecture:** Modify the existing `SettingsView.swift` to use a multi-section grouped List. Add a `signOut()` method to `AppState`. No new files needed — all changes fit in existing files.

**Tech Stack:** SwiftUI, UIKit (for `UIApplication.shared.open`), Foundation (`Bundle.main`)

---

### Task 1: Add signOut() method to AppState

**Files:**
- Modify: `ios/JLWLoader/AppState.swift` (after `removeOrg` method, ~line 131)
- Test: `ios/JLWLoaderTests/AppStateTests.swift`

**Step 1: Write the failing test**

Add to `AppStateTests.swift`:

```swift
func testSignOutClearsAllCredentials() async {
    let mockAPI = MockAPIClient()
    mockAPI.authenticateResult = .success(AuthResponse(orgId: "org1", orgName: "N12345", apiKey: "key1"))
    let appState = AppState(apiClient: mockAPI)

    // Manually set up state as if authenticated with two orgs
    try? await appState.authenticate(accessCode: "CODE1")
    mockAPI.authenticateResult = .success(AuthResponse(orgId: "org2", orgName: "N67890", apiKey: "key2"))
    try? await appState.authenticate(accessCode: "CODE2")

    XCTAssertEqual(appState.credentials.count, 2)
    XCTAssertTrue(appState.isAuthenticated)

    appState.signOut()

    XCTAssertEqual(appState.credentials.count, 0)
    XCTAssertNil(appState.activeOrgId)
    XCTAssertFalse(appState.isAuthenticated)
}
```

**Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild test -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:JLWLoaderTests/AppStateTests/testSignOutClearsAllCredentials 2>&1 | tail -20`
Expected: FAIL — `signOut()` does not exist

**Step 3: Implement signOut() in AppState**

Add after `removeOrg(_:)` (~line 131) in `ios/JLWLoader/AppState.swift`:

```swift
func signOut() {
    credentials.removeAll()
    activeOrgId = nil
    try? KeychainService.saveAllCredentials([])
    KeychainService.delete(key: Constants.Keychain.activeOrgId)
    isAuthenticated = false
}
```

**Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild test -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:JLWLoaderTests/AppStateTests/testSignOutClearsAllCredentials 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add ios/JLWLoader/AppState.swift ios/JLWLoaderTests/AppStateTests.swift
git commit -m "feat: add signOut() method to AppState"
```

---

### Task 2: Restructure SettingsView with new sections

**Files:**
- Modify: `ios/JLWLoader/SettingsView.swift`

**Step 1: Add Support section after Aircraft section**

In the `List` body of `SettingsView`, after the closing `}` of `Section("Aircraft")` (line 33), add:

```swift
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
```

**Step 2: Add Account section with Sign Out**

After the Support section, add:

```swift
Section("Account") {
    Button(role: .destructive) {
        showSignOutConfirmation = true
    } label: {
        Text("Sign Out")
    }
}
```

**Step 3: Add version footer**

After the Account section (still inside the `List`), add:

```swift
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
```

**Step 4: Add state and confirmation alert**

Add `@State private var showSignOutConfirmation = false` to the SettingsView properties (after `showAddAircraft`).

Add the `.alert` modifier to the `List` (before `.navigationTitle`):

```swift
.alert("Sign Out", isPresented: $showSignOutConfirmation) {
    Button("Cancel", role: .cancel) { }
    Button("Sign Out", role: .destructive) {
        appState.signOut()
        dismiss()
    }
} message: {
    Text("This will remove all aircraft and sign you out.")
}
```

**Step 5: Build to verify no compiler errors**

Run: `cd ios && xcodebuild build -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPad (10th generation)' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios/JLWLoader/SettingsView.swift
git commit -m "feat: add support links, sign out, and version to settings"
```

---

### Task 3: Run full test suite

**Step 1: Run all tests**

Run: `cd ios && xcodebuild test -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPad (10th generation)' 2>&1 | tail -30`
Expected: All tests pass, no regressions

**Step 2: Final commit if any fixes needed**

Only if tests revealed issues that required changes.
