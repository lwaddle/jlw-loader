# iOS App — Phase 1 Design (Download Only)

## Scope

Phase 1 delivers the core loop: access code entry → manifest check → download ZIP → verify checksum → store locally. No USB transfer — that's Phase 2.

### What's included
- First launch: access code entry, exchange for API key, Keychain storage
- Main screen: check manifest, show update status, download ZIP, verify checksum, store in app Documents
- All UI states adapted for download-only (no transfer states)

### What's excluded
- USB drive selection, wipe, or file extraction
- UIDocumentPickerViewController integration
- Background URLSession (adds complexity; standard foreground download is fine for ~150-180MB on WiFi)

## Tech Stack

| Component | Choice |
|---|---|
| UI | SwiftUI (iOS 16+, iPhone only) |
| Networking | URLSession (foreground, progress via async bytes) |
| Checksum | CryptoKit SHA-256 |
| Secure storage | Keychain Services (thin wrapper, iCloud sync enabled) |
| Dependencies | None — zero third-party libraries |
| Bundle ID | `com.jlwav.loader` |

## Authentication Flow

### First launch
1. App launches → checks Keychain for stored API key
2. No key found → show access code entry screen
3. Pilot enters code (e.g., `JLW-7294`)
4. App calls `POST /api/auth` with `{ "accessCode": "JLW-7294" }`
5. Worker returns `{ "apiKey": "key_abc123...", "orgId": "jlw-aviation" }`
6. App stores `apiKey` and `orgId` in Keychain → navigates to main screen

### Subsequent launches
1. App launches → finds API key in Keychain → goes straight to main screen

### Keychain storage
- Two items: `apiKey` (string) and `orgId` (string)
- Stored with `kSecAttrSynchronizable: true` for iCloud Keychain sync to new devices
- Simple wrapper: `KeychainService` with `save(key, value)`, `read(key)`, `delete(key)`

### Error cases
- Invalid code → "Access code not recognized. Contact your administrator."
- No internet → "Unable to connect. Check your internet connection and try again."
- Both show inline below the text field, with retry

### No logout in v1
If a pilot needs to re-enter a code (rare — only on code rotation), they delete and reinstall. A settings/reset screen can come later.

## Main Screen States

One screen that adapts based on state:

### State 1 — Checking
- Shown briefly on launch while fetching manifest
- Spinner + "Checking for updates..."

### State 2 — New Update Available
- Manifest's `uploadedAt` is newer than locally stored `lastDownloadedAt`
- Shows: filename, upload date (relative), file size
- Primary button: "Download Update"

### State 3 — Downloading
- Progress bar with percentage
- Shows bytes downloaded / total
- Cancel button

### State 4 — Verifying
- Brief state after download completes
- "Verifying download..." with spinner while SHA-256 runs
- Auto-transitions to State 5 on success

### State 5 — Download Complete
- "Download complete" with checkmark
- Shows filename and date
- Terminal state for Phase 1 (becomes "Ready to Transfer" in Phase 2)
- "Check for Updates" button to re-check manifest

### State 6 — Up to Date
- Locally stored `lastDownloadedAt` >= manifest's `uploadedAt`
- "Current" with checkmark, shows last downloaded date
- "Check for Updates" button

### State 7 — Error / No Internet
- Shows last known state if available
- "Last checked: X hours ago"
- Retry button

### State persistence (UserDefaults)
```
lastDownloadedAt: "2026-03-17T16:30:00Z"
lastDownloadedFilename: "update-2026-03.zip"
lastCheckedAt: "2026-03-18T09:00:00Z"
```

Comparison logic: `manifest.uploadedAt > lastDownloadedAt` → new update available.

## Network Layer & Download Flow

### API client
- Simple struct wrapping URLSession — `APIClient`
- Base URL hardcoded to worker URL (easy to swap for testing)
- All pilot requests include `X-API-Key` header from Keychain
- Returns decoded JSON or typed errors

### Manifest check
1. `GET /api/manifest` with `X-API-Key` header
2. Response: `{ orgId, packageFilename, packageSizeBytes, packageChecksum, uploadedAt }`
3. Compare `uploadedAt` against stored `lastDownloadedAt`

### Download flow
1. `POST /api/download` → presigned R2 URL (15-min expiry)
2. Download ZIP from presigned URL with progress tracking
3. Write to app's Documents directory as original filename
4. Only one ZIP stored at a time — delete previous before saving new one

### Checksum verification
1. Read downloaded file from disk
2. Compute SHA-256 using CryptoKit
3. Compare to `packageChecksum` from manifest (strip `sha256:` prefix)
4. Match → update UserDefaults, transition to "Download Complete"
5. Mismatch → delete file, retry once automatically, then show error

### Error handling

| Scenario | Behavior |
|---|---|
| Manifest fetch fails | Show error state with retry |
| Presigned URL request fails | Show error with retry |
| Download interrupted | Show error with retry (no auto-resume in v1) |
| Checksum mismatch | Auto-retry once, then error |
| Disk full | "Not enough storage on this device" |

## Project Structure

```
JLWLoader/
  JLWLoaderApp.swift          # App entry point, root view selection
  AccessCodeView.swift         # First-launch access code entry
  MainView.swift               # Single screen with all states
  KeychainService.swift        # Save/read/delete Keychain items
  APIClient.swift              # URLSession wrapper, all API calls
  DownloadManager.swift        # Download + checksum + file storage
  Manifest.swift               # Codable struct for manifest JSON
  AppState.swift               # ObservableObject driving MainView states
  Constants.swift              # API base URL, Keychain keys, UserDefaults keys
  Assets.xcassets/             # App icon (placeholder for v1)
```

~10 files. No MVVM folders, no protocol abstractions, no DI framework.

### Key design decisions
- `AppState` is an `ObservableObject` with `@Published` properties (iOS 16 target). Drives all view state from one place.
- `DownloadManager` owns download, progress, checksum verification, and file management. `AppState` calls into it.
- `JLWLoaderApp.swift` checks Keychain on launch — API key exists → `MainView`, otherwise → `AccessCodeView`.

## Backend Endpoints (reference)

The Worker is already built. These are the endpoints the iOS app talks to:

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/auth` | Access code in body | Exchange code for API key |
| GET | `/api/manifest` | `X-API-Key` header | Get current update manifest |
| POST | `/api/download` | `X-API-Key` header | Get presigned R2 download URL (15-min expiry) |

Worker base URL: `https://loader.jlwav.com` (or `*.workers.dev` subdomain)

## Phase 2 Roadmap: USB Transfer

This section provides enough context to pick up USB transfer work without re-discovering decisions.

### Scope
- Detect/select USB drive via `UIDocumentPickerViewController` (wrapped for SwiftUI)
- Wipe drive contents (recursive delete, preserve FAT32 filesystem)
- Extract ZIP directly to USB drive path
- File-by-file progress during extraction
- Completion and error states

### Key decisions (from main spec)
- No reformat — recursive delete is sufficient for FAT32
- iOS requires user to select drive via system Files picker (no workaround)
- Extraction goes directly to USB — no double-buffering to local storage
- Drive must be FAT32, not exFAT or NTFS

### Expected file structure on USB (from EXAMPLE_DATA_LOAD/)
```
USB Root/
  E-Maps/
    E-Maps/
      *.LUH, *.LUP files
    crate.xml
  J7_Americas/
    *.ACM, *.AII, *.AIP, ... (33 files)
    crate.xml
  Jeppesen_Disk_06-2026/
    (contents TBD)
  XM_GWx/
    (contents TBD)
```

### Open questions for Phase 2 design
1. Should the app validate extracted structure matches expected folders before marking complete?
2. Do we need background URLSession at this point?
3. Should "Ready to Transfer" survive app restart, or require re-download?
4. Verify file count post-extraction, or trust the write?

### State changes in Phase 2
- "Download Complete" becomes "Ready to Transfer" with "Select USB Drive" button
- New: "Transferring" state with per-file progress
- New: "Transfer Complete" — "Drive is ready for the aircraft"
- `lastTransferredAt` replaces `lastDownloadedAt` as the "up to date" comparison

### New files expected
- `USBTransferManager.swift` — drive wipe, extraction, progress
- `DocumentPickerView.swift` — SwiftUI wrapper for UIDocumentPickerViewController
- Updates to `MainView.swift` and `AppState.swift` for new states

## Prerequisites

Before building:
- Register bundle ID `com.jlwav.loader` in App Store Connect
- Xcode 15+ installed
- Active Apple Developer Program membership under JLW Aviation
