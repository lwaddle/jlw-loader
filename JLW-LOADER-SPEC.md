# JLW Loader — Technical Specification
**Version 1.1 | March 2026**
**JLW Aviation**

---

## 1. Project Overview

JLW Loader is a two-component system that allows flight department personnel to receive avionics database updates and transfer them to a USB drive — without a laptop. The system consists of a **private web uploader** (used by the administrator from a desktop browser) and an **iOS app** (used by pilots in the field).

### Problem Being Solved
Avionics database updates (Rockwell Collins Pro Line 21 / DBU-5000) must be loaded every 28 days via a FAT32-formatted USB 2.0 flash drive. Currently this requires a laptop and technical knowledge. JLW Loader reduces the pilot's role to: open app → download → plug in drive → transfer.

### Guiding Principles
- **Pilot-proof UI.** Three taps maximum to complete a transfer.
- **Zero infrastructure to babysit.** Cloudflare's managed services handle uptime.
- **Multi-tenant from day one.** Architecture supports multiple independent flight departments without code changes.
- **Right-sized.** Designed for 20–30 users across a handful of organizations. Not over-engineered.
- **Current package only.** Pilots always see exactly one update — the current cycle. No version history, no choices to make.

---

## 2. App Identity

| Field | Value |
|---|---|
| **App Name** | JLW Loader |
| **Developer** | JLW Aviation |
| **Bundle ID** | `com.jlwaviation.loader` |
| **App Store Category** | Utilities |
| **Minimum iOS Version** | iOS 16 |
| **Platform** | iPhone |
| **Distribution** | App Store (public listing, access-code gated) |
| **R2 Bucket** | `jlw-loader-updates` |
| **Worker Route** | `loader.jlwaviation.com` or `*.workers.dev` subdomain |

### Apple Developer Account
An active Apple Developer Program membership ($99/year) is required under JLW Aviation before App Store or TestFlight distribution. The bundle ID `com.jlwaviation.loader` must be registered in App Store Connect and cannot be changed after submission.

---

## 3. System Architecture

```
ADMINISTRATOR (Mac, any browser)
        │
        │  HTTPS (access-code protected)
        ▼
┌─────────────────────────┐
│   Web Uploader          │  Cloudflare Pages (free tier)
│   (HTML + Vanilla JS)   │  Static site, no server needed
└────────────┬────────────┘
             │  Uploads via pre-signed R2 URL
             ▼
┌─────────────────────────┐
│   Cloudflare R2 Bucket  │  jlw-loader-updates
│                         │  Organized by organization ID
│  /orgs/{orgId}/         │
│    manifest.json        │
│    update-2026-03.zip   │
└────────────┬────────────┘
             │  Served via
             ▼
┌─────────────────────────┐
│   Cloudflare Worker     │  Serverless gatekeeper (free tier)
│                         │  Validates access code → org mapping
│                         │  Returns pre-signed download URLs
└────────────┬────────────┘
             │  HTTPS
             ▼
┌─────────────────────────┐
│   JLW Loader (iOS)      │  Pilot's iPhone (iOS 16+)
│                         │  Downloads update package
│                         │  Wipes USB drive
│                         │  Writes files to USB drive
└─────────────────────────┘
```

### How Multi-Tenancy Works

Each flight department (organization) gets:
- A unique `orgId` (e.g., `"jlw-aviation"`)
- A unique access code (e.g., `JLW-7294`) — human readable, easy to communicate
- Their own isolated path in R2: `/orgs/jlw-aviation/`

The Worker maps friendly access codes to orgIds. Adding a new organization requires adding one environment variable to the Worker config — no database, no redeployment, no downtime.

---

## 4. Authentication & Access Control

JLW Loader uses a deliberate, minimal auth strategy. There are three separate concerns, each handled differently:

### 4.1 Pilot → iOS App (Access Code, entered once)

Pilots are not required to create accounts or log in. On first launch, the app shows a single access code entry screen. The pilot enters their org's access code (provided by the administrator out of band — text or email). The code is stored in the iOS Keychain and never needs to be entered again.

**Access code lifecycle:**
- Entered once at first install
- Persists in iCloud Keychain — survives phone upgrades automatically
- If iCloud Keychain is disabled, pilot re-enters the same code on a new device
- Only invalidated if the administrator deliberately rotates the key in Cloudflare

**Why not per-user accounts?**
All pilots have identical permissions — download and transfer. There is no reason to know which individual pilot downloaded a package. Accounts would add friction (login screens, forgotten passwords, expired sessions) with no operational benefit.

**Why not bake the code into the app binary?**
The app is distributed via the public App Store. A code baked into the binary would be accessible to anyone who downloads the app. By requiring code entry on first launch, a stranger who downloads JLW Loader from the App Store sees only a code entry screen — they cannot access any data without a valid code.

### 4.2 iOS App → Cloudflare Worker (API Key in Keychain)

When the pilot enters their access code, the app exchanges it with the Worker for the actual API key, which is then stored in the Keychain. Every subsequent request includes this key in the `X-API-Key` header. The Worker validates it and scopes all responses to the correct org.

The access code and API key can be different values — the friendly code (`JLW-7294`) maps to a longer internal key (`key_abc123xyz...`) that the Worker uses internally. This allows codes to be rotated without changing the human-friendly value if needed.

### 4.3 Admin → Web Uploader (Per-Admin Credentials)

Each administrator has their own username and password for the web uploader. The Worker maps admin credentials to their orgId — when Loren logs in, the uploader is automatically scoped to JLW Aviation's R2 path. A second org's admin logs in and sees only their own data.

This means access codes can be issued to additional organizations without sharing any upload capability. Each org admin manages their own packages independently.

**Threat model summary:**

| Threat | Protection |
|---|---|
| Stranger downloads update files | Access code required — Worker returns 401 without it |
| Stranger pushes malicious update | Impossible — iOS app has no upload capability whatsoever |
| Admin uploads to wrong org's path | Per-admin credentials scope all writes to their orgId |
| Intercepted download | HTTPS on all connections |
| Pilot leaves department | Rotate access code — one-time re-entry for remaining pilots |

---

## 5. Backend Infrastructure

### 5.1 Cloudflare R2 Bucket (`jlw-loader-updates`)

**Bucket structure:**
```
jlw-loader-updates/
  orgs/
    jlw-aviation/
      manifest.json
      update-2026-03.zip
    other-org/
      manifest.json
      update-2026-03.zip
```

**manifest.json schema:**
```json
{
  "orgId": "jlw-aviation",
  "packageFilename": "update-2026-03.zip",
  "packageSizeBytes": 187234816,
  "packageChecksum": "sha256:abc123...",
  "uploadedAt": "2026-03-17T16:30:00Z"
}
```

The iOS app fetches only the manifest on launch (tiny JSON) to determine whether a new update exists before committing to a 150–300MB download.

### 5.2 Cloudflare Worker

A single Worker handles all API traffic.

**Worker environment variables:**
```
# Pilot access codes → orgId mapping
ACCESS_CODE_JLW_AVIATION  = "JLW-7294"   → orgId: "jlw-aviation"
ACCESS_CODE_OTHER_ORG     = "OTH-5531"   → orgId: "other-org"

# Admin credentials → orgId mapping
ADMIN_LOREN     = "password_abc..."  → orgId: "jlw-aviation"
ADMIN_FRIEND    = "password_xyz..."  → orgId: "other-org"
```

Adding a new organization = add two environment variables (one pilot code, one admin credential). Zero downtime, no redeployment.

**Endpoints:**

| Method | Path | Auth | Response |
|---|---|---|---|
| POST | `/api/auth` | Access code in body | API key for Keychain storage |
| GET | `/api/manifest` | X-API-Key header | manifest.json for caller's org |
| POST | `/api/download` | X-API-Key header | Pre-signed R2 URL (15-min expiry) |
| POST | `/api/upload-url` | Admin credential | Pre-signed PUT URL scoped to admin's org |
| PATCH | `/api/manifest` | Admin credential | Update manifest after upload |

### 5.3 Compression Strategy

Update packages are zipped before upload. Navigation data and chart files compress well.

- Target: reduce ~300MB uncompressed to ~150–180MB
- Format: ZIP (iOS decompresses natively via `FileManager`)
- The manifest records compressed `packageSizeBytes` for accurate progress display
- Extraction goes directly to the USB drive path — no double-buffering to local storage

---

## 6. Web Uploader

### 6.1 Overview

A single-page web app hosted on Cloudflare Pages. Each admin logs in with their own credentials. Only administrators use this.

### 6.2 Tech Stack

- **HTML + vanilla JavaScript** — no framework, no build step, no npm
- **Cloudflare Pages** — free static hosting with automatic HTTPS
- **Per-admin credentials** — validated by the Worker, scoped to orgId

### 6.3 UI Flow

```
[Login screen — username + password]
        │
        ▼
┌─────────────────────────────────────┐
│  JLW Aviation                       │
│─────────────────────────────────────│
│  Current Package                    │
│  Version: February 2026             │
│  Uploaded: 28 days ago              │
│  Size: 187 MB compressed            │
│─────────────────────────────────────│
│  Upload New Package                 │
│                                     │
│  Cycle:  [March 2026        ▼]      │
│  Notes:  [Nav, approach, terrain  ] │
│                                     │
│  [ Drop ZIP file here, or click ]   │
│                                     │
│  [        Upload Package        ]   │
└─────────────────────────────────────┘
```

### 6.4 Upload Sequence

1. Admin logs in — Worker validates credentials and returns a scoped session token
2. Admin fills in cycle info and selects ZIP file
3. Browser calls Worker `/api/upload-url` to get a pre-signed R2 PUT URL
4. Browser uploads ZIP directly to R2 using the pre-signed URL (large file bypasses the Worker entirely — efficient, no timeout risk)
5. Browser calls Worker `/api/manifest` PATCH to update manifest.json
6. UI confirms success and displays new version info

### 6.5 Pre-Upload Validation (Optional v1 Enhancement)

The uploader can inspect the ZIP contents client-side and validate that the expected DBU-5000 file structure is present before uploading. Surfaces a warning if something looks wrong — catches packaging mistakes before pilots encounter a bad update.

---

## 7. iOS App — JLW Loader

### 7.1 Tech Stack

- **SwiftUI** — UI
- **URLSession** with background download configuration — download continues if pilot locks phone or switches apps
- **FileManager** — USB drive file operations (wipe + write)
- **UIDocumentPickerViewController** (wrapped as SwiftUI view) — USB drive selection
- **CryptoKit** — SHA-256 checksum verification post-download
- **Keychain** — secure API key storage
- No third-party dependencies

### 7.2 First Launch Flow

```
┌─────────────────────────────────────┐
│                                     │
│         JLW Loader                  │
│                                     │
│  Enter your access code to          │
│  get started.                       │
│                                     │
│  [ JLW-____                     ]   │
│                                     │
│  [          Continue            ]   │
│                                     │
│  Contact your administrator         │
│  if you need an access code.        │
│                                     │
└─────────────────────────────────────┘
```

Access code is validated against the Worker. On success, the API key is stored in the Keychain and the pilot never sees this screen again — including after upgrading to a new iPhone (iCloud Keychain restores it automatically).

### 7.3 Main Screen States

The app has one primary screen. It adapts based on current state:

**State 1 — New Update Available**
```
┌─────────────────────────────────────┐
│  JLW Loader                    🟢   │
│─────────────────────────────────────│
│                                     │
│  🟢 New Update Available            │
│                                     │
│  March 2026 Cycle                   │
│  Released March 1, 2026             │
│  187 MB download                    │
│                                     │
│  Nav data · Approach plates         │
│  Terrain · Obstacles                │
│                                     │
│  [      Download Update      ]      │
│                                     │
│  Last checked: just now             │
└─────────────────────────────────────┘
```

**State 2 — Downloading**
```
┌─────────────────────────────────────┐
│  JLW Loader                         │
│─────────────────────────────────────│
│                                     │
│  Downloading March 2026...          │
│                                     │
│  ████████████░░░░░░  63%            │
│  118 MB of 187 MB                   │
│                                     │
│  You can lock your phone.           │
│  Download continues in background.  │
│                                     │
│  [         Cancel            ]      │
│                                     │
└─────────────────────────────────────┘
```

**State 3 — Downloaded, Ready to Transfer**
```
┌─────────────────────────────────────┐
│  JLW Loader                    🔵   │
│─────────────────────────────────────│
│                                     │
│  🔵 Ready to Transfer               │
│                                     │
│  March 2026 — downloaded ✓          │
│  Verified ✓                         │
│                                     │
│  Connect USB drive to iPhone        │
│  using your USB-C to USB-A adapter  │
│                                     │
│  [     Select USB Drive      ]      │
│                                     │
└─────────────────────────────────────┘
```

**State 4 — Transferring**
```
┌─────────────────────────────────────┐
│  JLW Loader                         │
│─────────────────────────────────────│
│                                     │
│  Transferring to USB...             │
│                                     │
│  Clearing drive contents... ✓       │
│  Writing files...                   │
│  ████████████░░░░  67%              │
│  142 of 212 files                   │
│                                     │
│  ⚠️ Do not disconnect drive         │
│                                     │
└─────────────────────────────────────┘
```

**State 5 — Transfer Complete**
```
┌─────────────────────────────────────┐
│  JLW Loader                    ✅   │
│─────────────────────────────────────│
│                                     │
│  ✅ Transfer Complete               │
│                                     │
│  212 files written                  │
│  March 2026 Cycle                   │
│                                     │
│  Drive is ready for the aircraft.   │
│  You can safely disconnect          │
│  the USB drive.                     │
│                                     │
│  [           Done            ]      │
│                                     │
└─────────────────────────────────────┘
```

**State 6 — Up to Date**
```
┌─────────────────────────────────────┐
│  JLW Loader                    ✅   │
│─────────────────────────────────────│
│                                     │
│  ✅ Current                         │
│                                     │
│  March 2026 Cycle                   │
│  Last transferred: March 3, 2026    │
│                                     │
│  Next cycle due ~March 29           │
│                                     │
│  [     Check for Updates     ]      │
│                                     │
└─────────────────────────────────────┘
```

**State 7 — No Internet**
```
┌─────────────────────────────────────┐
│  JLW Loader                    ⚪   │
│─────────────────────────────────────│
│                                     │
│  ⚠️ Unable to Check                 │
│                                     │
│  No internet connection.            │
│                                     │
│  Last known: March 2026 Cycle       │
│  Last checked: 3 hours ago          │
│                                     │
│  [         Retry             ]      │
│                                     │
└─────────────────────────────────────┘
```

### 7.4 Badge Logic

The green dot badge appears on the main screen (not as an iOS app icon badge — no notification permissions needed):

```
manifest version ≠ local transferred version  →  🟢 New Update Available
downloaded but not yet transferred            →  🔵 Ready to Transfer
manifest version = local transferred version  →  ✅ Current
manifest fetch in progress                    →  ⚪ Checking...
no internet, last state known                 →  ⚠️ Unable to Check
```

Badge clears only when a transfer completes successfully. Download to phone ≠ loaded on airplane.

### 7.5 USB Drive Handling

**Why wiping is sufficient (no reformat needed):**
The DBU-5000 requires two things: FAT32 filesystem and correct files in the correct structure. Recursive delete removes all files and folders while preserving the FAT32 filesystem. From the loader's perspective, the drive is clean. A full reformat is only needed if the filesystem itself becomes corrupted — a rare event requiring a computer regardless.

**Wipe sequence:**
1. App gets sandbox access to USB drive via document picker
2. Enumerate all contents of drive root
3. Delete each item recursively via `FileManager.removeItem(at:)`
4. Verify drive is empty before proceeding
5. Extract ZIP contents directly to USB drive path
6. Verify file count matches manifest expectation
7. Display completion

**Drive picker UX:**
iOS requires the user to select the USB drive via the system Files picker — apps cannot access external storage without this user-initiated grant. This is one extra tap but is reliable, requires no special entitlements, and is App Store safe. The app instructs the pilot to connect the drive first, then tap "Select USB Drive."

### 7.6 Checksum Verification

After download completes, before extraction begins:
1. Compute SHA-256 of downloaded ZIP using CryptoKit
2. Compare to `packageChecksum` in manifest
3. Match → proceed to transfer
4. Mismatch → delete file, retry download once automatically, then surface error if second attempt also fails

This catches corrupted downloads before they reach the airplane.

### 7.7 Error Handling

| Scenario | App Behavior |
|---|---|
| No internet on launch | Shows last known state + "last checked X hours ago" |
| Invalid access code | Clear error: "Access code not recognized. Contact your administrator." |
| Download interrupted | Resumes automatically via background URLSession |
| Checksum mismatch | Silent re-download once, then error with retry button |
| No USB drive connected | "Connect your USB drive before selecting" |
| Drive too small | "Drive has insufficient space (needs X MB, drive has Y MB free)" |
| Drive not FAT32 | "This drive must be FAT32 formatted. Please reformat on a computer and try again." |
| Write fails mid-transfer | "Transfer failed. Do not use this drive for the update. Reconnect the drive and try again." |
| Drive disconnected mid-transfer | Same as write failure + "Drive was disconnected during transfer." |

### 7.8 Version Persistence

The app stores the last successfully transferred version in `UserDefaults`:
```
lastTransferredVersion: "2026-03"
lastTransferredDate: "2026-03-03T09:14:00Z"
```

On launch, manifest version is compared to `lastTransferredVersion` to determine badge state. This persists across app restarts and device upgrades.

---

## 8. USB Drive Requirements

Document these for pilots:

- **Format:** FAT32 (not exFAT, not NTFS)
- **Interface:** USB 2.0 Type-A
- **Adapter:** USB-C to USB-A (standard — Loren already has these)
- **Minimum capacity:** 1 GB (packages are ~300MB uncompressed)
- **Recommended:** Keep two identical drives pre-formatted to FAT32, labeled "AVIONICS UPDATE." If one gets corrupted, swap to the spare while the first is reformatted on a computer.

---

## 9. DBU-5000 File Structure

**This must be documented before writing any code.**

The DBU-5000 likely expects files in a specific directory layout. Before building, perform one manual update cycle and document:

- Exact folder and subfolder names
- Exact filenames and extensions
- Whether any index or metadata files are required
- Whether any files must appear in the drive root vs. a subdirectory

This structure becomes the template the app recreates on every transfer, and the baseline for the uploader's optional pre-upload validation.

---

## 10. Build Order (Claude Code Sessions)

Each item is a focused, completable Claude Code session:

**Phase 1 — Backend**
1. Cloudflare Worker — access code auth, manifest and download endpoints, admin upload endpoints
2. R2 bucket setup — folder structure, manifest.json schema
3. Web uploader — HTML/JS login, current package display, file upload with progress, manifest update

**Phase 2 — iOS Core**
4. Xcode project scaffold — `com.jlwaviation.loader`, SwiftUI structure, Keychain wrapper
5. First launch flow — access code entry screen, Worker auth exchange, Keychain storage
6. Network layer — manifest fetch, background URLSession download, checksum verification
7. Main screen — all seven states with correct badge logic and transitions

**Phase 3 — iOS USB Transfer**
8. Document picker integration — USB drive selection, sandbox access grant
9. Drive wipe — recursive delete with verification
10. ZIP extraction to USB — direct extraction to drive path with file progress
11. Completion and error states

**Phase 4 — Polish**
12. All error handling edge cases (drive full, not FAT32, disconnect mid-transfer)
13. App icon, launch screen, App Store screenshots
14. App Store metadata, privacy policy (no user data collected)
15. TestFlight internal testing before App Store submission

---

## 11. Scaling to 20–30 Users

**Adding a new organization (5 minutes of work):**
1. Generate a friendly access code (e.g., `ORG-8812`)
2. Add two lines to the Worker environment variables — pilot access code and admin credential
3. Send the access code to the new org's pilots out of band
4. Send admin credentials to the new org's administrator
5. Their R2 path is created automatically on first upload

**What doesn't change as you scale:**
- No database to manage
- No user accounts to provision
- No support burden per pilot
- Cloudflare free tier handles this traffic comfortably (R2 free tier: 10GB storage, 10M reads/month)

**If you eventually want more control** (usage analytics, remote code revocation, push notifications for new cycles), a Cloudflare D1 database (SQLite, free tier) can be added to the Worker without changing the iOS app.

**If you ever want to charge for access:**
The tenant model maps cleanly to a simple SaaS flow. A new org pays → access code is provisioned → they enter it in the app. No App Store IAP complexity. Stripe + a Worker endpoint could automate provisioning entirely.

---

## 12. What's Out of Scope (Intentionally)

- Push notifications for new update cycles — pilots check manually, which is appropriate for a 28-day cadence
- Update history / previous packages — current cycle only, one thing to do
- Multiple aircraft per organization — single aircraft, extend manifest schema later if needed
- Android app — not worth it at this scale
- Automatic update scheduling — pilots initiate manually, correct for aviation safety
- Over-the-air drive formatting — iOS limitation, not possible
- Per-pilot audit logs — no individual user identity in the system by design
