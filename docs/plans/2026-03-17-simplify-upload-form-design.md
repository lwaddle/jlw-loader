# Simplify Upload Form

## Problem

The upload form has four metadata fields (version, cycle number, release date, description) that don't match how Loren actually uses the system. He uploads multi-cycle packages, so "cycle number" is meaningless. Pilots just need the most recent package — they don't care about version strings or release dates.

## Decision

Remove all metadata fields. The upload becomes: drop a ZIP, click Upload. The manifest stores only what the system needs.

## Manifest schema (after)

```json
{
  "orgId": "jlw-aviation",
  "packageFilename": "update-2026-03.zip",
  "packageSizeBytes": 187234816,
  "packageChecksum": "sha256:abc123...",
  "uploadedAt": "2026-03-17T16:30:00Z"
}
```

Removed: `version`, `cycleNumber`, `releaseDate`, `description`.

`uploadedAt` is auto-generated at upload time, not user-entered.

## iOS app impact

The app compares `uploadedAt` against its stored `lastDownloadedAt` timestamp instead of comparing version strings.

## Current Package display

Dashboard shows: filename, size, checksum, and relative upload time ("Uploaded 2 days ago").

## Files to change

- `web-uploader/index.html` — remove form fields
- `web-uploader/app.js` — remove field validation, simplify upload payload
- `web-uploader/style.css` — remove unused `.form-row` styles
- `worker/src/types.ts` — simplify `ManifestData` interface
- `JLW-LOADER-SPEC.md` — update manifest schema
- `worker/README.md` — update manifest example and API docs
