# Web Uploader — Folder Drop Support Design

## Goal

Allow the admin to drag-and-drop multiple folders (e.g., `E-Maps/`, `J7_Americas/`) directly into the web uploader instead of manually zipping them first. The uploader builds the ZIP client-side and uploads it — same result, less friction.

## Behavior

**Drag & drop** supports two modes, auto-detected:
- **Single `.zip` file** — current behavior, upload directly
- **Folders or multiple files** — read all files recursively, build ZIP in browser, then upload

**Click to browse** — unchanged, opens file picker for selecting a single ZIP file.

**Drop zone text:** "Drop folders or ZIP file here, or click to select ZIP"

## Technical Approach

- **JSZip** loaded via CDN (`<script>` tag, ~100KB). No npm, no build step.
- **Folder reading:** `DataTransferItem.webkitGetAsEntry()` + recursive `DirectoryReader.readEntries()` to traverse dropped folder trees.
- **Auto-generated filename:** `update-YYYY-MM-DD.zip` based on today's date when building from folders.
- **File structure preservation:** Dropped folders appear at the ZIP root. Dropping `E-Maps/` and `J7_Americas/` produces a ZIP with `E-Maps/...` and `J7_Americas/...` — same as manual zipping.

## Progress Steps (folder mode)

1. "Reading files..." — scanning dropped folders
2. "Building ZIP... X files" — JSZip compression
3. "Computing checksum..." — SHA-256 (same as current)
4. "Uploading..." — presigned PUT to R2 (same as current)

## What Doesn't Change

- Worker endpoints
- R2 bucket structure
- iOS app
- Manifest format
- SHA-256 checksum flow
- Presigned URL upload flow

The ZIP that reaches R2 is identical to a manually created one.
