# Web Uploader Folder Drop — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow the admin to drag-and-drop multiple folders into the web uploader; the browser builds a ZIP client-side and uploads it using the existing flow.

**Architecture:** Add JSZip via CDN. Modify the drop handler to detect folders vs ZIP files. For folders, recursively read all files using the `webkitGetAsEntry()` API, build a ZIP with JSZip, then feed the resulting Blob into the existing upload pipeline (hash → presigned URL → upload → manifest update).

**Tech Stack:** Vanilla JS, JSZip (CDN), existing Cloudflare Worker API (no changes)

---

### Task 1: Add JSZip CDN and update drop zone text

**Files:**
- Modify: `web-uploader/index.html`

**Step 1: Add JSZip script tag before app.js**

In `index.html`, add this line right before the `<script src="app.js"></script>` tag:

```html
<script src="https://cdn.jsdelivr.net/npm/jszip@3/dist/jszip.min.js"></script>
```

**Step 2: Update drop zone text and hint**

Change the drop zone content (lines 94-95):

```html
<p class="drop-text">Drop folders or ZIP file here, or <span class="drop-link">browse</span></p>
<p class="drop-hint">Drag update folders directly, or select a .zip file</p>
```

**Step 3: Verify the page loads without errors**

Open `web-uploader/index.html` in a browser. Check the console — JSZip should load without errors. Verify `window.JSZip` exists in the console.

**Step 4: Commit**

```bash
git add web-uploader/index.html
git commit -m "feat: add JSZip CDN and update drop zone text for folder support"
```

---

### Task 2: Add folder reading utility function

**Files:**
- Modify: `web-uploader/app.js`

**Step 1: Add `readAllEntries` helper function**

Add this after the `// ── FILE SELECTION` section comment (before the `dropZone.addEventListener` lines), around line 309:

```javascript
// ── FOLDER READING ───────────────────────────────────────────────

/**
 * Recursively read all files from a list of DataTransferItems.
 * Returns an array of { path: 'E-Maps/crate.xml', file: File }
 */
async function readDroppedItems(dataTransferItems) {
  const entries = [];
  for (const item of dataTransferItems) {
    const entry = item.webkitGetAsEntry();
    if (entry) entries.push(entry);
  }

  const files = [];
  await Promise.all(entries.map(e => readEntry(e, '', files)));
  return files;
}

/**
 * Recursively read a FileSystemEntry into the files array.
 * prefix is the path so far (e.g., 'E-Maps/E-Maps/').
 */
async function readEntry(entry, prefix, files) {
  if (entry.isFile) {
    const file = await new Promise(resolve => entry.file(resolve));
    const path = prefix + entry.name;
    // Skip macOS resource forks
    if (!path.startsWith('__MACOSX/') && !entry.name.startsWith('._')) {
      files.push({ path, file });
    }
  } else if (entry.isDirectory) {
    const dirReader = entry.createReader();
    const dirEntries = await readDirectoryFully(dirReader);
    await Promise.all(dirEntries.map(e => readEntry(e, prefix + entry.name + '/', files)));
  }
}

/**
 * DirectoryReader.readEntries() only returns up to 100 entries at a time.
 * Call repeatedly until it returns an empty array.
 */
function readDirectoryFully(dirReader) {
  return new Promise((resolve, reject) => {
    const allEntries = [];
    function readBatch() {
      dirReader.readEntries(entries => {
        if (entries.length === 0) {
          resolve(allEntries);
        } else {
          allEntries.push(...entries);
          readBatch();
        }
      }, reject);
    }
    readBatch();
  });
}
```

**Step 2: Test manually**

Open the web uploader in a browser. In the console, verify that dragging a folder over the drop zone doesn't break anything (existing behavior should still work).

**Step 3: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: add recursive folder reading utilities for drag-and-drop"
```

---

### Task 3: Add ZIP building function

**Files:**
- Modify: `web-uploader/app.js`

**Step 1: Add `buildZipFromFiles` function**

Add after the folder reading utilities:

```javascript
// ── ZIP BUILDING ─────────────────────────────────────────────────

/**
 * Build a ZIP file from an array of { path, file } entries using JSZip.
 * Returns a File object with an auto-generated name.
 */
async function buildZipFromFiles(fileEntries, onProgress) {
  const zip = new JSZip();

  // Add all files to the ZIP
  for (let i = 0; i < fileEntries.length; i++) {
    const entry = fileEntries[i];
    const arrayBuffer = await entry.file.arrayBuffer();
    zip.file(entry.path, arrayBuffer);
    onProgress('reading', 'Reading files... ' + (i + 1) + ' of ' + fileEntries.length,
      Math.round(((i + 1) / fileEntries.length) * 50));
  }

  // Generate ZIP blob
  onProgress('building', 'Building ZIP...', 50);
  const blob = await zip.generateAsync(
    { type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } },
    function (metadata) {
      const pct = 50 + Math.round(metadata.percent / 2);
      onProgress('building', 'Compressing... ' + Math.round(metadata.percent) + '%', pct);
    }
  );

  // Create a File object from the Blob (so existing upload code works unchanged)
  const today = new Date().toISOString().slice(0, 10);
  const filename = 'update-' + today + '.zip';
  return new File([blob], filename, { type: 'application/zip' });
}
```

**Step 2: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: add buildZipFromFiles using JSZip with progress reporting"
```

---

### Task 4: Update drop handler to detect folders vs ZIP

**Files:**
- Modify: `web-uploader/app.js`

**Step 1: Replace the existing drop event handler**

Replace the current `dropZone.addEventListener('drop', ...)` handler (around line 322-327) with:

```javascript
dropZone.addEventListener('drop', async (e) => {
  e.preventDefault();
  dropZone.classList.remove('drag-over');

  const items = e.dataTransfer.items;
  if (!items || items.length === 0) return;

  // Detect mode: single ZIP file → direct upload, otherwise → build ZIP from folders
  if (items.length === 1 && items[0].kind === 'file') {
    const file = items[0].getAsFile();
    if (file && file.name.toLowerCase().endsWith('.zip')) {
      selectFile(file);
      return;
    }
  }

  // Folder/multi-file mode: read all entries and build ZIP
  uploadResult.hidden = true;
  progressWrap.hidden = false;
  setProgress('reading', 'Scanning folders...', 0);

  try {
    const fileEntries = await readDroppedItems(items);

    if (fileEntries.length === 0) {
      showResult('error', 'No files found in the dropped items.');
      progressWrap.hidden = true;
      return;
    }

    setProgress('reading', fileEntries.length + ' files found. Building ZIP...', 10);

    const zipFile = await buildZipFromFiles(fileEntries, setProgress);

    progressWrap.hidden = true;
    selectFile(zipFile);
  } catch (err) {
    showResult('error', 'Failed to read folders: ' + err.message);
    progressWrap.hidden = true;
  }
});
```

**Step 2: Update `selectFile` to accept any file (not just .zip)**

The `selectFile` function currently rejects non-`.zip` files. When we build a ZIP from folders, the resulting File already has a `.zip` name, so this check still passes. No change needed — verify this is the case.

**Step 3: Test manually**

1. Open the web uploader in a browser (log in)
2. Drag a single `.zip` file → should show file info (existing behavior)
3. Drag a folder from Finder → should scan files, build ZIP, show file info with auto-generated name
4. Drag multiple folders → same as above, all folders combined into one ZIP
5. Click "browse" → should open file picker for ZIP selection (unchanged)

**Step 4: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: detect folders vs ZIP on drop, build ZIP from folders automatically"
```

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Add JSZip CDN + update drop zone text | `index.html` |
| 2 | Folder reading utilities (recursive entry traversal) | `app.js` |
| 3 | ZIP building function (JSZip + progress) | `app.js` |
| 4 | Update drop handler (auto-detect folders vs ZIP) | `app.js` |

**Total: 2 files modified, 4 commits. No Worker or iOS changes.**

After all tasks: admin can drag 4 update folders directly into the uploader. The browser reads them, builds a ZIP with deflate compression, and uploads using the existing pipeline. Single ZIP drag-and-drop still works as before.
