# Package History Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow admins to revert to one of the last 5 uploaded packages without re-uploading.

**Architecture:** Extend `manifest.json` with a `history` array (max 5 entries). Add `POST /api/revert` endpoint. Update the web uploader frontend with a "Previous Packages" section and revert confirmation flow. Timestamp-based filenames prevent collisions.

**Tech Stack:** Cloudflare Worker (TypeScript), vanilla JS frontend, R2 storage.

---

### Task 1: Add history types to ManifestData

**Files:**
- Modify: `worker/src/types.ts:47-53`

**Step 1: Update the ManifestData interface**

Add `HistoryEntry` and extend `ManifestData`:

```typescript
/**
 * A previous package retained in manifest history.
 */
export interface HistoryEntry {
  packageFilename: string;
  packageSizeBytes: number;
  packageChecksum: string;
  uploadedAt: string;
}

/**
 * manifest.json stored in R2 at orgs/{orgId}/manifest.json
 */
export interface ManifestData {
  orgId: string;
  orgName?: string;
  packageFilename: string;
  packageSizeBytes: number;
  packageChecksum: string;
  uploadedAt: string;
  history?: HistoryEntry[];
}
```

**Step 2: Commit**

```bash
git add worker/src/types.ts
git commit -m "feat: add HistoryEntry type and history field to ManifestData"
```

---

### Task 2: Update PATCH /api/manifest to preserve history

**Files:**
- Modify: `worker/src/index.ts:260-287` (handlePatchManifest function)

**Step 1: Rewrite handlePatchManifest to read existing manifest, push current package to history, trim to 5, and delete evicted ZIPs**

Replace the current `handlePatchManifest` function (lines 260-287) with:

```typescript
async function handlePatchManifest(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  let incoming: Record<string, unknown>;
  try {
    incoming = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  // Force orgId from JWT (security)
  incoming.orgId = admin.orgId;
  if (!incoming.orgName) {
    incoming.orgName = admin.orgName;
  }

  // Read existing manifest to preserve history
  const existingObj = await env.UPDATES_BUCKET.get(`orgs/${admin.orgId}/manifest.json`);
  let history: Array<{
    packageFilename: string;
    packageSizeBytes: number;
    packageChecksum: string;
    uploadedAt: string;
  }> = [];

  if (existingObj) {
    const existing = await existingObj.json<Record<string, unknown>>();

    // Push current active package into history (if one exists)
    if (existing.uploadedAt && existing.packageFilename) {
      history = Array.isArray(existing.history) ? [...existing.history] : [];
      history.unshift({
        packageFilename: existing.packageFilename as string,
        packageSizeBytes: existing.packageSizeBytes as number,
        packageChecksum: existing.packageChecksum as string,
        uploadedAt: existing.uploadedAt as string,
      });

      // Trim to 5 and delete evicted ZIPs
      while (history.length > 5) {
        const evicted = history.pop()!;
        try {
          await env.UPDATES_BUCKET.delete(`orgs/${admin.orgId}/${evicted.packageFilename}`);
        } catch (err) {
          console.error('Failed to delete evicted ZIP:', evicted.packageFilename, err);
        }
      }
    }
  }

  const manifest = { ...incoming, history };

  await env.UPDATES_BUCKET.put(
    `orgs/${admin.orgId}/manifest.json`,
    JSON.stringify(manifest, null, 2),
    { httpMetadata: { contentType: 'application/json' } },
  );

  return json({ success: true, orgId: admin.orgId });
}
```

**Step 2: Verify the Worker builds**

Run: `cd worker && npm run build` (or `npx wrangler deploy --dry-run`)

**Step 3: Commit**

```bash
git add worker/src/index.ts
git commit -m "feat: preserve package history in PATCH /api/manifest"
```

---

### Task 3: Add POST /api/revert endpoint

**Files:**
- Modify: `worker/src/index.ts:89-113` (route table)
- Modify: `worker/src/index.ts` (add new handler function)

**Step 1: Add route to the switch statement**

Add after the `/api/upload-url` case (around line 101):

```typescript
case '/api/revert':
  if (request.method === 'POST') { response = await handleRevert(request, env); break; }
  response = errorResponse('Not found', 404); break;
```

**Step 2: Add the handleRevert function**

Add this function after `handlePatchManifest`:

```typescript
// ---------------------------------------------------------------------------
// POST /api/revert — revert to a previous package (admin auth only)
//
// Body: { "packageFilename": "update-2026-03-05-100000.zip" }
// Swaps the selected history entry into the active slot.
// ---------------------------------------------------------------------------

async function handleRevert(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  let body: { packageFilename?: string };
  try {
    body = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  if (!body.packageFilename) {
    return errorResponse('packageFilename is required', 400);
  }

  // Read current manifest
  const manifestObj = await env.UPDATES_BUCKET.get(`orgs/${admin.orgId}/manifest.json`);
  if (!manifestObj) {
    return errorResponse('No manifest found', 404);
  }

  const manifest = await manifestObj.json<Record<string, unknown>>();
  const history: Array<{
    packageFilename: string;
    packageSizeBytes: number;
    packageChecksum: string;
    uploadedAt: string;
  }> = Array.isArray(manifest.history) ? [...(manifest.history as any[])] : [];

  // Find the requested entry in history
  const idx = history.findIndex(h => h.packageFilename === body.packageFilename);
  if (idx === -1) {
    return errorResponse('Package not found in history', 404);
  }

  // Swap: push current active into history, promote selected entry
  const selected = history.splice(idx, 1)[0];

  if (manifest.uploadedAt && manifest.packageFilename) {
    history.unshift({
      packageFilename: manifest.packageFilename as string,
      packageSizeBytes: manifest.packageSizeBytes as number,
      packageChecksum: manifest.packageChecksum as string,
      uploadedAt: manifest.uploadedAt as string,
    });
  }

  // Trim to 5 and delete evicted ZIPs
  while (history.length > 5) {
    const evicted = history.pop()!;
    try {
      await env.UPDATES_BUCKET.delete(`orgs/${admin.orgId}/${evicted.packageFilename}`);
    } catch (err) {
      console.error('Failed to delete evicted ZIP:', evicted.packageFilename, err);
    }
  }

  // Build updated manifest
  const updated = {
    orgId: admin.orgId,
    orgName: manifest.orgName || admin.orgName,
    packageFilename: selected.packageFilename,
    packageSizeBytes: selected.packageSizeBytes,
    packageChecksum: selected.packageChecksum,
    uploadedAt: selected.uploadedAt,
    history,
  };

  await env.UPDATES_BUCKET.put(
    `orgs/${admin.orgId}/manifest.json`,
    JSON.stringify(updated, null, 2),
    { httpMetadata: { contentType: 'application/json' } },
  );

  return json({ success: true, orgId: admin.orgId });
}
```

**Step 3: Verify the Worker builds**

Run: `cd worker && npm run build`

**Step 4: Commit**

```bash
git add worker/src/index.ts
git commit -m "feat: add POST /api/revert endpoint for package rollback"
```

---

### Task 4: Generate timestamp-based filenames in the web uploader

**Files:**
- Modify: `web-uploader/app.js:360-383` (buildZipFromFiles function)
- Modify: `web-uploader/app.js:480-526` (upload flow, for direct ZIP uploads)

**Step 1: Add a filename generation helper**

Add this function near the top of app.js (after the DOM refs section, around line 47):

```javascript
/**
 * Generate a timestamp-based filename: update-YYYY-MM-DD-HHMMSS.zip
 */
function generatePackageFilename() {
  var now = new Date();
  var pad = function (n) { return n.toString().padStart(2, '0'); };
  return 'update-' + now.getFullYear()
    + '-' + pad(now.getMonth() + 1)
    + '-' + pad(now.getDate())
    + '-' + pad(now.getHours())
    + pad(now.getMinutes())
    + pad(now.getSeconds())
    + '.zip';
}
```

**Step 2: Update buildZipFromFiles to use the new filename**

In `buildZipFromFiles` (line 380-382), replace the filename generation:

```javascript
// OLD (lines 380-382):
  var today = new Date().toISOString().slice(0, 10);
  var filename = 'update-' + today + '.zip';
  return new File([blob], filename, { type: 'application/zip' });

// NEW:
  return new File([blob], generatePackageFilename(), { type: 'application/zip' });
```

**Step 3: Update the upload flow for direct ZIP drops**

When a user drops a pre-made ZIP, the file keeps its original name. We should rename it to use our timestamp format. In the upload submit handler (line 497), change:

```javascript
// OLD (line 497):
    const urlResp = await apiCall('POST', '/api/upload-url', { filename: selectedFile.name });

// NEW:
    const uploadFilename = generatePackageFilename();
    const urlResp = await apiCall('POST', '/api/upload-url', { filename: uploadFilename });
```

And update the manifest call (lines 506-512):

```javascript
// OLD (lines 506-512):
    await apiCall('PATCH', '/api/manifest', {
      packageFilename: selectedFile.name,
      packageSizeBytes: selectedFile.size,
      packageChecksum: 'sha256:' + checksum,
      uploadedAt: new Date().toISOString(),
      orgName: clerk.organization && clerk.organization.name,
    });

// NEW:
    await apiCall('PATCH', '/api/manifest', {
      packageFilename: uploadFilename,
      packageSizeBytes: selectedFile.size,
      packageChecksum: 'sha256:' + checksum,
      uploadedAt: new Date().toISOString(),
      orgName: clerk.organization && clerk.organization.name,
    });
```

**Step 4: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: use timestamp-based filenames for uploaded packages"
```

---

### Task 5: Add "Previous Packages" section to HTML

**Files:**
- Modify: `web-uploader/index.html:48-60` (after current-pkg-card section)

**Step 1: Add the history section**

Insert after the closing `</section>` of `current-pkg-card` (after line 60) and before the Access Code section (line 63):

```html
      <!-- Previous Packages -->
      <section class="card" id="history-card" hidden>
        <div class="card-header">
          <h2>Previous Packages</h2>
        </div>
        <div id="history-list" class="history-list">
          <!-- Populated by JS -->
        </div>
        <div id="history-empty" class="pkg-empty" hidden>
          <p>No previous packages.</p>
        </div>
      </section>
```

**Step 2: Commit**

```bash
git add web-uploader/index.html
git commit -m "feat: add previous packages section to HTML"
```

---

### Task 6: Add CSS for the history list

**Files:**
- Modify: `web-uploader/style.css` (add after the `.pkg-empty` block, around line 516)

**Step 1: Add history list styles**

Insert after the `.muted` rule (line 516):

```css
/* ── HISTORY LIST ──────────────────────────────────────────────── */

.history-list {
  display: flex;
  flex-direction: column;
  gap: 1px;
  background: var(--border-subtle);
  border-radius: var(--radius);
  overflow: hidden;
}

.history-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 14px 16px;
  background: var(--bg-card);
  gap: 12px;
}

.history-item-info {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.history-item-name {
  font-size: 13px;
  font-family: var(--font-mono);
  color: var(--text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.history-item-meta {
  font-size: 12px;
  color: var(--text-muted);
  font-family: var(--font-mono);
}

.btn-revert {
  flex-shrink: 0;
  padding: 6px 12px;
  font-size: 12px;
  font-weight: 500;
  font-family: var(--font-mono);
  color: var(--amber);
  background: none;
  border: 1px solid var(--amber-dim);
  border-radius: var(--radius);
  cursor: pointer;
  transition: color 0.15s, background 0.15s, border-color 0.15s;
  white-space: nowrap;
}

.btn-revert:hover {
  background: var(--amber-dim);
  border-color: var(--amber);
}
```

**Step 2: Commit**

```bash
git add web-uploader/style.css
git commit -m "feat: add CSS for package history list"
```

---

### Task 7: Render package history and implement revert in JS

**Files:**
- Modify: `web-uploader/app.js` (add DOM refs, render function, revert handler)

**Step 1: Add DOM refs**

Add after the `orgDropdown` ref (line 46):

```javascript
const historyCard  = document.getElementById('history-card');
const historyList  = document.getElementById('history-list');
const historyEmpty = document.getElementById('history-empty');
```

**Step 2: Add renderHistory function**

Add after the `renderManifest` function (after line 228):

```javascript
function renderHistory() {
  var history = (currentManifest && currentManifest.history) || [];

  if (history.length === 0) {
    historyCard.hidden = true;
    return;
  }

  historyCard.hidden = false;
  historyEmpty.hidden = true;

  // Clear previous items
  while (historyList.firstChild) {
    historyList.removeChild(historyList.firstChild);
  }

  history.forEach(function (entry) {
    var item = document.createElement('div');
    item.className = 'history-item';

    var info = document.createElement('div');
    info.className = 'history-item-info';

    var name = document.createElement('span');
    name.className = 'history-item-name';
    name.textContent = entry.packageFilename;

    var meta = document.createElement('span');
    meta.className = 'history-item-meta';
    meta.textContent = formatBytes(entry.packageSizeBytes) + ' \u00B7 ' + formatRelativeDate(entry.uploadedAt);

    info.appendChild(name);
    info.appendChild(meta);

    var btn = document.createElement('button');
    btn.className = 'btn-revert';
    btn.textContent = 'Make Active';
    btn.addEventListener('click', function () {
      revertToPackage(entry.packageFilename);
    });

    item.appendChild(info);
    item.appendChild(btn);
    historyList.appendChild(item);
  });
}
```

**Step 3: Add revertToPackage function**

Add after `renderHistory`:

```javascript
async function revertToPackage(packageFilename) {
  if (!confirm('Are you sure you want to make ' + packageFilename + ' the active package?\n\nAll pilots will see this as a new update.')) {
    return;
  }

  try {
    await apiCall('POST', '/api/revert', { packageFilename: packageFilename });
    currentManifest = await apiCall('GET', '/api/manifest');
    renderManifest();
    renderHistory();
    showResult('success', 'Package reverted to ' + packageFilename);
  } catch (err) {
    showResult('error', 'Failed to revert: ' + err.message);
  }
}
```

**Step 4: Call renderHistory from showDashboard**

In the `showDashboard` function (line 161-165), add `renderHistory()` after `renderManifest()`:

```javascript
// OLD (lines 161-165):
function showDashboard() {
  loginView.hidden = true;
  dashboardView.hidden = false;
  renderManifest();
}

// NEW:
function showDashboard() {
  loginView.hidden = true;
  dashboardView.hidden = false;
  renderManifest();
  renderHistory();
}
```

**Step 5: Call renderHistory after successful upload**

In the upload success handler (around line 515-517), add `renderHistory()`:

```javascript
// OLD (lines 514-518):
    currentManifest = await apiCall('GET', '/api/manifest');
    renderManifest();
    showResult('success', 'Package uploaded successfully.');
    resetUploadUI();

// NEW:
    currentManifest = await apiCall('GET', '/api/manifest');
    renderManifest();
    renderHistory();
    showResult('success', 'Package uploaded successfully.');
    resetUploadUI();
```

**Step 6: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: render package history list with revert support"
```

---

### Task 8: End-to-end manual test

**Step 1: Start local dev environment**

Run the Worker locally: `cd worker && npx wrangler dev`
Serve the web uploader: `cd web-uploader && npx serve .` (or however local dev is set up)

**Step 2: Test upload with history**

1. Upload a first package (folder or ZIP). Verify:
   - Active package shows correctly
   - No "Previous Packages" section (no history yet)
   - Filename is timestamp-based (e.g., `update-2026-03-19-143022.zip`)

2. Upload a second package. Verify:
   - Active package updates to the new one
   - "Previous Packages" section appears with 1 entry (the first package)

3. Upload a third package. Verify:
   - History now shows 2 entries (most recent first)

**Step 3: Test revert**

1. Click "Make Active" on a history entry
2. Verify confirmation alert appears with the filename
3. Confirm. Verify:
   - Active package changes to the selected history entry
   - The previously active package moves into history
   - History list re-renders correctly

**Step 4: Test cancel**

1. Click "Make Active" on a history entry
2. Click Cancel on the confirmation alert
3. Verify nothing changes

**Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during manual testing"
```

---

### Task 9: Update CORS for revert endpoint

**Files:**
- Verify: `worker/src/index.ts:41`

**Step 1: Verify CORS handles POST**

Check that `Access-Control-Allow-Methods` already includes `POST` — it does (line 41: `'GET, POST, PATCH, DELETE, OPTIONS'`). No change needed, but verify the OPTIONS preflight returns correctly for `/api/revert`.

**Step 2: Commit if any changes needed**

(Likely no commit needed — CORS is already permissive enough.)
