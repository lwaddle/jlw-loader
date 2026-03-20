# Fixes + Single Access Code Design

**Date:** 2026-03-19
**Status:** Approved

## Context

Three items: two bugs from the multi-org implementation review and a simplification of the access code model.

## Changes

### Fix 1: Clear UserDefaults on org switch

In `AppState.switchOrg(to:)`, clear `lastDownloadedAt`, `lastDownloadedFilename`, `lastTransferredAt`, `lastTransferredFilename` before checking for updates. This prevents stale timestamps from org A causing incorrect status display for org B. Keep `lastCheckedAt` (not org-specific).

### Fix 2: Auto-check after removeOrg on 401

In `AppState.checkForUpdates()`, after `removeOrg(cred.orgId)` handles a 401, if `isAuthenticated` is still true (remaining orgs exist), recursively call `checkForUpdates()` to load the new active org's data.

### Single Auto-Generated Access Code

**Rationale:** Multiple access codes per org adds unnecessary complexity. One code per org is sufficient — pilots copy/paste it.

**Code format:** `XXX-XXXX` (3 chars, dash, 4 chars)
- Charset: `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (30 chars — excludes 0/O/1/I/L for clarity)
- Collision check against KV before saving

**Backend:**
- New endpoint: `POST /api/access-codes/regenerate` — deletes all existing codes for the org, generates a fresh `XXX-XXXX` code, returns it
- Existing `/api/auth` and access code lookup unchanged (iOS app still uses them)

**Web uploader UI:**
- Replace multi-code list + add form with single-code display
- Shows code prominently in mono font with copy button
- "Generate New Code" button with confirmation warning about distributing new code to pilots
- On first load: if org has 0 or multiple codes, auto-call regenerate to produce a single fresh code

**Migration:** Delete all old codes and auto-generate fresh ones (app is still in development, no migration needed).

**No iOS changes needed.**
