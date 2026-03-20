# Package History Design

## Problem

Uploading a ~200 MB package takes a while. If the wrong package is uploaded, there's no way to revert — the admin must re-upload the correct one. Keeping a short history of previous packages allows quick rollback.

## Decision

Extend `manifest.json` with a `history` array (Approach A — manifest-based history). This is the simplest path: single source of truth, no new infrastructure, backward-compatible with the iOS app.

Alternatives considered:
- **Separate `history.json` file** — Rejected: two files to keep in sync, unnecessary complexity.
- **R2 object versioning** — Rejected: harder to query, enforce limits, and display in UI.

## Data Model

The existing top-level fields in `manifest.json` remain unchanged (iOS compatibility). A `history` array is added containing up to 5 previous package entries, most recent first.

```json
{
  "orgId": "jlw-aviation",
  "packageFilename": "update-2026-03-19-143022.zip",
  "packageSizeBytes": 187234816,
  "packageChecksum": "sha256:abc123...",
  "uploadedAt": "2026-03-19T14:30:22Z",
  "history": [
    {
      "packageFilename": "update-2026-03-05-100000.zip",
      "packageSizeBytes": 185000000,
      "packageChecksum": "sha256:def456...",
      "uploadedAt": "2026-03-05T10:00:00Z"
    }
  ]
}
```

### Filename generation

Filenames use timestamp precision to avoid collisions on same-day uploads: `update-YYYY-MM-DD-HHMMSS.zip` (e.g., `update-2026-03-19-143022.zip`).

## API Changes

### `PATCH /api/manifest` (modified)

When updating after a new upload:
1. Read current manifest from R2.
2. If a current active package exists, push it to `history[0]`.
3. If `history` exceeds 5 entries, pop the oldest and delete its ZIP from R2.
4. Write the new active package fields + updated history.

### `POST /api/revert` (new, admin auth)

Accepts `{ packageFilename }` to identify which history entry to activate:
1. Read current manifest.
2. Find the matching entry in `history`.
3. Push the current active package into `history`.
4. Promote the selected entry to active, remove it from `history`.
5. If `history` exceeds 5, trim oldest and delete its ZIP from R2.
6. Write updated manifest.

## Frontend Changes

### Previous Packages section

Below the active package display, show a "Previous Packages" list. Each entry displays filename, size, upload date, and a "Make Active" button.

### Revert flow

1. User clicks "Make Active" on a history entry.
2. Confirmation alert: "Are you sure you want to make [filename] the active package? All pilots will see this as a new update."
3. On confirm, call `POST /api/revert`.
4. On success, re-fetch and re-render manifest.

### Empty state

If no history exists, show "No previous packages" or hide the section.

## Edge Cases

- **ZIP cleanup:** When a history entry is evicted, delete its ZIP from R2. If the delete fails, log but don't block — orphaned ZIPs are harmless.
- **First upload:** `history` starts as `[]`. No special handling.
- **Migration:** Missing `history` field treated as `[]`. No migration needed.
- **Concurrent uploads:** Not a concern (single admin). Read-modify-write on manifest is not atomic but acceptable.

## Limits

- 5 historical packages + 1 active = 6 total per org (~1.2 GB at 200 MB each).
- R2 free tier storage is not a concern.
