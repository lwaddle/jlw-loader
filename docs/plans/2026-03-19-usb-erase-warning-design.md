# USB Erase Warning Alert — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a confirmation alert before USB drive erase/transfer so pilots can cancel if they selected the wrong drive.

**Architecture:** Intercept the document picker callback in MainView, store the pending URL in AppState, and present a SwiftUI `.alert()`. On confirm, proceed with the existing `transferToUSB` flow. On cancel, clear the pending URL.

**Tech Stack:** SwiftUI, XCTest

---

### Task 1: Add pending drive state to AppState

**Files:**
- Modify: `ios/JLWLoader/AppState.swift:17-22` (published properties)

**Step 1: Add the new properties**

Add after line 22 (`@Published var activeOrgId: String?`):

```swift
@Published var showEraseConfirmation: Bool = false
var pendingDriveURL: URL?
```

**Step 2: Add a helper to get the drive name from a URL**

Add in the `// MARK: - Helpers` section (after line 379):

```swift
/// Extract the volume name from a drive URL for display in alerts.
func driveName(for url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.volumeNameKey])
    return values?.volumeName ?? "the selected USB drive"
}
```

**Step 3: Add a method to confirm the erase**

Add after the `driveName` helper:

```swift
func confirmErase(driveURL: URL) {
    pendingDriveURL = driveURL
    showEraseConfirmation = true
}

func cancelErase() {
    pendingDriveURL = nil
}
```

**Step 4: Commit**

```bash
git add ios/JLWLoader/AppState.swift
git commit -m "feat: add pending drive state and erase confirmation helpers to AppState"
```

---

### Task 2: Wire up the alert in MainView

**Files:**
- Modify: `ios/JLWLoader/MainView.swift:34-44` (document picker sheet)

**Step 1: Change the document picker callback to store URL instead of transferring**

Replace the `.sheet(isPresented: $appState.showDocumentPicker)` block (lines 34-44) with:

```swift
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
```

**Step 2: Add the `.alert()` modifier**

Add immediately after the `.sheet(isPresented: $appState.showDocumentPicker)` block:

```swift
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
```

**Step 3: Commit**

```bash
git add ios/JLWLoader/MainView.swift
git commit -m "feat: add USB erase confirmation alert before transfer"
```

---

### Task 3: Build and verify

**Step 1: Build the project**

Run: `cd ios && xcodebuild build -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`
Expected: BUILD SUCCEEDED

**Step 2: Run existing tests to check for regressions**

Run: `cd ios && xcodebuild test -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`
Expected: All tests pass

**Step 3: Commit if any fixes were needed**
