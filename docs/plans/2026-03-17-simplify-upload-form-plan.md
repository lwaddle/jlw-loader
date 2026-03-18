# Simplify Upload Form — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove version, cycle number, release date, and description fields from the upload form and manifest. Upload becomes: drop ZIP, click Upload.

**Architecture:** The web uploader stops collecting metadata. The manifest PATCH payload shrinks to just filename, size, checksum, and uploadedAt (auto-generated). The Worker's ManifestData type is updated to match. The "Current Package" display shows only the remaining fields.

**Tech Stack:** Vanilla HTML/CSS/JS (web uploader), TypeScript (Worker)

---

### Task 1: Remove form fields from HTML

**Files:**
- Modify: `web-uploader/index.html:78-96`

**Step 1:** Remove the entire `.form-row` div (lines 79-92) containing version, cycle-number, and release-date inputs. Also remove the description field div (lines 93-96). The form should go straight from `<form id="upload-form">` to the drop zone.

**After edit, the form should be:**
```html
<form id="upload-form">
  <!-- Drop Zone -->
  <div id="drop-zone" class="drop-zone">
    ...
  </div>
  ...rest unchanged...
</form>
```

### Task 2: Simplify app.js — remove field validation and metadata from upload

**Files:**
- Modify: `web-uploader/app.js:225-234` (validation)
- Modify: `web-uploader/app.js:244-290` (upload flow)
- Modify: `web-uploader/app.js:117-175` (renderManifest)

**Step 1:** Remove the form field validation listeners (lines 225-227) and simplify `validateUploadForm()` to just check `selectedFile`:
```js
function validateUploadForm() {
  uploadBtn.disabled = !selectedFile;
}
```

**Step 2:** Simplify the upload submit handler. Remove lines reading version/cycleNumber/releaseDate/description. Use `selectedFile.name` as the filename. The manifest PATCH payload becomes:
```js
await apiCall('PATCH', '/api/manifest', {
  packageFilename: selectedFile.name,
  packageSizeBytes: selectedFile.size,
  packageChecksum: 'sha256:' + checksum,
  uploadedAt: new Date().toISOString(),
});
```
Update the success message to: `'Package uploaded successfully.'`

**Step 3:** Simplify `renderManifest()`. Change the "no package" check from `!m.version` to `!m.uploadedAt`. Remove version/cycle/releaseDate/description from the fields array. Keep only:
```js
const fields = [
  { label: 'Filename',     value: m.packageFilename || '—', mono: true },
  { label: 'Package Size', value: sizeDisplay },
  { label: 'Uploaded',     value: uploadedDisplay },
];
if (m.packageChecksum) {
  fields.push({ label: 'Checksum', value: m.packageChecksum, mono: true, fullWidth: true });
}
```

### Task 3: Clean up unused CSS

**Files:**
- Modify: `web-uploader/style.css`

**Step 1:** Remove `.form-row` rule (lines 187-192) and `.form-row > .field + .field` rule (lines 139-141). Also remove the `.form-row` responsive override in the media query (lines 631-633). Remove unused `input[type="date"]` styles (lines 177-185) and `input[type="number"]` from the input selector (line 150).

### Task 4: Update ManifestData type

**Files:**
- Modify: `worker/src/types.ts:57-67`

**Step 1:** Simplify the ManifestData interface:
```ts
export interface ManifestData {
  orgId: string;
  packageFilename: string;
  packageSizeBytes: number;
  packageChecksum: string;
  uploadedAt: string;
}
```

### Task 5: Update docs — worker README and spec

**Files:**
- Modify: `worker/README.md` — update manifest example in API Reference (lines 263-276) and the GET /api/manifest "no package yet" response
- Modify: `JLW-LOADER-SPEC.md` — update manifest schema (lines 152-158)

**Step 1:** Update the manifest JSON examples in both files to match the new schema (remove version, cycleNumber, releaseDate, description).

### Task 6: Commit

```bash
git add web-uploader/index.html web-uploader/app.js web-uploader/style.css worker/src/types.ts worker/README.md JLW-LOADER-SPEC.md
git commit -m "Simplify upload form: remove version/cycle/date/description fields

Upload is now just: drop ZIP, click Upload. Manifest stores filename,
size, checksum, and uploadedAt timestamp. No user-entered metadata."
```

### Task 7: Deploy and verify

**Step 1:** Deploy web uploader:
```bash
cd web-uploader && npx wrangler pages deploy . --project-name=jlw-loader-admin
```

**Step 2:** Verify at `https://loader.jlwav.com/`:
- Login shows dashboard
- Upload form has only drop zone + button (no metadata fields)
- Upload a test ZIP — succeeds
- Current Package card shows filename, size, uploaded time, checksum
