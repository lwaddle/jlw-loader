# iOS Multi-Org Support Design

**Date:** 2026-03-19
**Status:** Approved

## Context

The iOS app currently supports one access code / one org per device. Pilots who manage multiple aircraft (each represented as a Clerk org) need to enter additional access codes and switch between orgs to download the correct updates for each aircraft. One USB per aircraft — no mixing databases.

## Design

### Data Model

**Keychain storage (replaces single-credential model):**
- `com.jlwav.loader.credentials` — JSON array of `[{ orgId, orgName, apiKey }]`
- `com.jlwav.loader.activeOrgId` — currently selected org slug

**Migration:** On first launch after update, if old single-credential keys exist (`com.jlwav.loader.apiKey`, `com.jlwav.loader.orgId`), migrate them into the new array format using orgId as fallback display name. Delete old keys.

**UserDefaults** remain per-device (not per-org) — they track physical state (what's on this phone/USB).

### Backend Change

Add `orgName` to `/api/auth` response:
```json
{ "apiKey": "key_abc...", "orgId": "jlw-aviation", "orgName": "JLW Aviation" }
```

Store `orgName` in KV alongside the access code entry when admin creates codes. No Clerk API call at auth time.

### Settings View

- **Access:** Gear icon in MainView nav bar, visible only when idle (`upToDate`, `updateAvailable`, `error`). Hidden during active operations.
- **Contents:**
  - List of added aircraft showing org name, active org has checkmark
  - Tap a different org to switch (dismisses Settings, auto-checks for updates)
  - "Add Aircraft" button opens access code entry sheet
  - Swipe-to-delete removes an org's credentials

### App State Changes

- `AppState` gains `credentials: [OrgCredential]` and `activeOrgId: String`
- `APIClient` reads from the active credential instead of directly from Keychain
- **Switch:** Update activeOrgId, clear manifest, reset status, dismiss Settings, auto-check
- **Add:** Append to credentials array, make active, auto-check
- **Remove:** Delete from array. If active, switch to next. If last, return to access code screen.

### Edge Cases

- **Duplicate org:** If access code resolves to an already-added org, show error
- **Revoked key (401):** Clear only the affected credential, not all. Switch to next if active was revoked.
- **Migrated names:** Use orgId as fallback display name until orgName is available

### What's NOT Changing

- Download, manifest, USB transfer flows — all scope by API key already
- No new backend endpoints
- No changes to Clerk org model
