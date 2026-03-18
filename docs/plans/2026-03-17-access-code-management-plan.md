# Access Code Management Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the ACCESS_CODES Wrangler secret with a KV-backed system, add CRUD API endpoints, and build an admin UI for managing pilot access codes.

**Architecture:** KV namespace stores access codes with two key patterns: `code:<code>` for lookups and `org:<orgId>:codes` for listing. Three new admin-only endpoints behind Clerk auth. Dashboard gets a new card for managing codes.

**Tech Stack:** Cloudflare Workers KV, existing vanilla JS frontend, Clerk for admin auth

---

### Task 1: Create KV Namespace and Update wrangler.toml

**Files:**
- Modify: `worker/wrangler.toml`

**Step 1: Create the KV namespace**

Run:
```bash
cd worker && npx wrangler kv namespace create ACCESS_CODES_KV
```

Note the namespace ID from the output.

**Step 2: Add KV binding to wrangler.toml**

Add after the `[[r2_buckets]]` section:

```toml
# ── KV namespace binding ─────────────────────────────────────────────────
[[kv_namespaces]]
binding = "ACCESS_CODES_KV"
id = "<namespace-id-from-step-1>"
```

Remove the `ACCESS_CODES` line from the secrets comments:

```toml
# ── Secrets (set via CLI, never committed) ────────────────────────────────
# Run each of these once before first deploy:
#
#   wrangler secret put R2_ACCESS_KEY_ID
#   wrangler secret put R2_SECRET_ACCESS_KEY
#   wrangler secret put CF_ACCOUNT_ID
```

**Step 3: Commit**

```bash
git add worker/wrangler.toml
git commit -m "Add KV namespace binding for access codes"
```

---

### Task 2: Update Env Type and Remove ACCESS_CODES Secret

**Files:**
- Modify: `worker/src/types.ts`

**Step 1: Update types.ts**

Replace the entire file with:

```typescript
/**
 * Cloudflare Worker environment bindings.
 *
 * Secrets (set via `wrangler secret put <NAME>`):
 *   R2_ACCESS_KEY_ID     – R2 S3-compatible API access key
 *   R2_SECRET_ACCESS_KEY – R2 S3-compatible API secret key
 *
 * Vars (set in wrangler.toml):
 *   CF_ACCOUNT_ID    – Cloudflare account ID (used for R2 S3 endpoint)
 *   R2_BUCKET_NAME   – R2 bucket name
 *   CLERK_ISSUER     – Clerk JWT issuer URL
 *   CLERK_JWKS_URL   – Clerk JWKS endpoint URL
 *
 * KV Namespaces:
 *   ACCESS_CODES_KV  – Pilot access codes and API keys
 */
export interface Env {
  // R2 binding (native, for direct reads/writes)
  UPDATES_BUCKET: R2Bucket;

  // KV namespace
  ACCESS_CODES_KV: KVNamespace;

  // Secrets
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;

  // Vars
  CF_ACCOUNT_ID: string;
  R2_BUCKET_NAME: string;
  CLERK_ISSUER: string;
  CLERK_JWKS_URL: string;
}

/**
 * Value stored in KV at key `code:<accessCode>`.
 */
export interface AccessCodeEntry {
  orgId: string;
  apiKey: string;
}

/**
 * manifest.json stored in R2 at orgs/{orgId}/manifest.json
 */
export interface ManifestData {
  orgId: string;
  packageFilename: string;
  packageSizeBytes: number;
  packageChecksum: string;
  uploadedAt: string;
}
```

**Step 2: Verify TypeScript compiles**

Run: `cd worker && npx tsc --noEmit`
Expected: Errors in auth.ts and index.ts (they still reference `env.ACCESS_CODES` — fixed in next tasks)

**Step 3: Commit**

```bash
git add worker/src/types.ts
git commit -m "Update Env type: replace ACCESS_CODES secret with KV binding"
```

---

### Task 3: Rewrite auth.ts for KV

**Files:**
- Modify: `worker/src/auth.ts`

**Step 1: Rewrite auth.ts**

Replace the entire file with:

```typescript
import { AccessCodeEntry } from './types';

// ---------------------------------------------------------------------------
// Access code lookups (pilot auth) — backed by KV
// ---------------------------------------------------------------------------

/**
 * Look up an access code entry from KV.
 * KV key format: `code:<accessCode>`
 */
export async function findByAccessCode(
  kv: KVNamespace,
  code: string,
): Promise<AccessCodeEntry | null> {
  const entry = await kv.get<AccessCodeEntry>(`code:${code}`, 'json');
  return entry ?? null;
}

/**
 * Reverse-lookup: given an API key, find the orgId it belongs to.
 * Lists all codes for efficiency — KV doesn't support value queries.
 * For small code counts (< 100) this is fine.
 */
export async function findOrgByApiKey(
  kv: KVNamespace,
  apiKey: string,
): Promise<string | null> {
  const list = await kv.list({ prefix: 'code:' });
  for (const key of list.keys) {
    const entry = await kv.get<AccessCodeEntry>(key.name, 'json');
    if (entry && constantTimeEqual(entry.apiKey, apiKey)) {
      return entry.orgId;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Access code management (admin CRUD)
// ---------------------------------------------------------------------------

/** Generate a cryptographically random API key. */
export function generateApiKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return 'key_' + hex;
}

/** Get the list of access codes for an org from the org index. */
export async function listAccessCodes(
  kv: KVNamespace,
  orgId: string,
): Promise<string[]> {
  const codes = await kv.get<string[]>(`org:${orgId}:codes`, 'json');
  return codes ?? [];
}

/** Save the org index (list of access codes). */
async function saveOrgIndex(
  kv: KVNamespace,
  orgId: string,
  codes: string[],
): Promise<void> {
  await kv.put(`org:${orgId}:codes`, JSON.stringify(codes));
}

/**
 * Create a new access code. Returns the generated API key.
 * Throws if the code already exists.
 */
export async function createAccessCode(
  kv: KVNamespace,
  orgId: string,
  accessCode: string,
): Promise<string> {
  // Check for duplicate
  const existing = await kv.get(`code:${accessCode}`);
  if (existing !== null) {
    throw new Error('ACCESS_CODE_EXISTS');
  }

  const apiKey = generateApiKey();
  const entry: AccessCodeEntry = { orgId, apiKey };

  // Write code entry
  await kv.put(`code:${accessCode}`, JSON.stringify(entry));

  // Update org index
  const codes = await listAccessCodes(kv, orgId);
  codes.push(accessCode);
  await saveOrgIndex(kv, orgId, codes);

  return apiKey;
}

/**
 * Delete an access code.
 * Throws if the code does not exist.
 */
export async function deleteAccessCode(
  kv: KVNamespace,
  orgId: string,
  accessCode: string,
): Promise<void> {
  const existing = await kv.get(`code:${accessCode}`);
  if (existing === null) {
    throw new Error('ACCESS_CODE_NOT_FOUND');
  }

  // Delete code entry
  await kv.delete(`code:${accessCode}`);

  // Update org index
  const codes = await listAccessCodes(kv, orgId);
  const updated = codes.filter((c) => c !== accessCode);
  await saveOrgIndex(kv, orgId, updated);
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

/** Constant-time string comparison to prevent timing attacks. */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
```

**Step 2: Verify TypeScript compiles**

Run: `cd worker && npx tsc --noEmit`
Expected: Errors only in `index.ts` (still using old function signatures — fixed next task)

**Step 3: Commit**

```bash
git add worker/src/auth.ts
git commit -m "Rewrite auth.ts to use KV for access code lookups and CRUD"
```

---

### Task 4: Update index.ts — KV Auth + CRUD Endpoints

**Files:**
- Modify: `worker/src/index.ts`

**Step 1: Update imports**

Replace the import block at the top:

```typescript
import { Env } from './types';
import {
  findByAccessCode,
  findOrgByApiKey,
  listAccessCodes,
  createAccessCode,
  deleteAccessCode,
} from './auth';
import { verifyClerkToken } from './clerk';
import { createPresignedGetUrl, createPresignedPutUrl } from './presign';
```

**Step 2: Add DELETE to CORS allowed methods**

Change the `corsHeaders` function:

```typescript
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
```

**Step 3: Add access-codes route to the switch statement**

In the `fetch` handler, add a new case before `default`:

```typescript
        case '/api/access-codes':
          if (request.method === 'GET') { response = await handleListAccessCodes(request, env); break; }
          if (request.method === 'POST') { response = await handleCreateAccessCode(request, env); break; }
          if (request.method === 'DELETE') { response = await handleDeleteAccessCode(request, env); break; }
          response = errorResponse('Not found', 404); break;
```

**Step 4: Rewrite handleAuth to use KV**

```typescript
async function handleAuth(request: Request, env: Env): Promise<Response> {
  let body: { accessCode?: string };
  try {
    body = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  if (!body.accessCode) {
    return errorResponse('Access code is required', 400);
  }

  const entry = await findByAccessCode(env.ACCESS_CODES_KV, body.accessCode.trim());

  if (!entry) {
    return errorResponse(
      'Access code not recognized. Contact your administrator.',
      401,
    );
  }

  return json({ apiKey: entry.apiKey, orgId: entry.orgId });
}
```

**Step 5: Rewrite handleDownload to use KV**

Change lines that reference `parseAccessCodes`:

```typescript
async function handleDownload(request: Request, env: Env): Promise<Response> {
  const apiKey = request.headers.get('X-API-Key');
  if (!apiKey) {
    return errorResponse('Unauthorized', 401);
  }

  const orgId = await findOrgByApiKey(env.ACCESS_CODES_KV, apiKey);
  if (!orgId) {
    return errorResponse('Unauthorized', 401);
  }

  // Read manifest to get the current package filename
  const manifestObj = await env.UPDATES_BUCKET.get(`orgs/${orgId}/manifest.json`);
  if (!manifestObj) {
    return errorResponse('No update package available', 404);
  }

  const manifest = await manifestObj.json<{ packageFilename: string }>();
  const key = `orgs/${orgId}/${manifest.packageFilename}`;
  const downloadUrl = await createPresignedGetUrl(env, key, 900);

  return json({
    downloadUrl,
    filename: manifest.packageFilename,
    expiresIn: 900,
  });
}
```

**Step 6: Rewrite resolveOrgId to use KV**

```typescript
async function resolveOrgId(request: Request, env: Env): Promise<string | null> {
  // Pilot auth
  const apiKey = request.headers.get('X-API-Key');
  if (apiKey) {
    return findOrgByApiKey(env.ACCESS_CODES_KV, apiKey);
  }

  // Admin auth
  const admin = await authenticateAdmin(request, env);
  return admin?.orgId ?? null;
}
```

**Step 7: Add the three access-codes handler functions**

Add before the auth helpers section:

```typescript
// ---------------------------------------------------------------------------
// GET /api/access-codes — list access codes for the admin's org
// ---------------------------------------------------------------------------

async function handleListAccessCodes(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  const codeNames = await listAccessCodes(env.ACCESS_CODES_KV, admin.orgId);
  const codes = [];
  for (const code of codeNames) {
    const entry = await findByAccessCode(env.ACCESS_CODES_KV, code);
    if (entry) {
      codes.push({ accessCode: code, apiKey: entry.apiKey });
    }
  }

  return json({ codes });
}

// ---------------------------------------------------------------------------
// POST /api/access-codes — create a new access code
// ---------------------------------------------------------------------------

async function handleCreateAccessCode(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  let body: { accessCode?: string };
  try {
    body = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  const accessCode = body.accessCode?.trim();
  if (!accessCode) {
    return errorResponse('accessCode is required', 400);
  }
  if (accessCode.length > 20) {
    return errorResponse('accessCode must be 20 characters or less', 400);
  }

  try {
    const apiKey = await createAccessCode(env.ACCESS_CODES_KV, admin.orgId, accessCode);
    return json({ accessCode, apiKey }, 201);
  } catch (err) {
    if (err instanceof Error && err.message === 'ACCESS_CODE_EXISTS') {
      return errorResponse('Access code already exists', 409);
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// DELETE /api/access-codes — delete an access code
// ---------------------------------------------------------------------------

async function handleDeleteAccessCode(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  let body: { accessCode?: string };
  try {
    body = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  const accessCode = body.accessCode?.trim();
  if (!accessCode) {
    return errorResponse('accessCode is required', 400);
  }

  try {
    await deleteAccessCode(env.ACCESS_CODES_KV, admin.orgId, accessCode);
    return json({ success: true });
  } catch (err) {
    if (err instanceof Error && err.message === 'ACCESS_CODE_NOT_FOUND') {
      return errorResponse('Access code not found', 404);
    }
    throw err;
  }
}
```

**Step 8: Verify TypeScript compiles**

Run: `cd worker && npx tsc --noEmit`
Expected: PASS (exit code 0)

**Step 9: Commit**

```bash
git add worker/src/index.ts
git commit -m "Add access code CRUD endpoints and migrate auth to KV"
```

---

### Task 5: Add Access Codes Card to Dashboard HTML

**Files:**
- Modify: `web-uploader/index.html`

**Step 1: Add the Access Codes card**

Insert between the Current Package `</section>` (line 57) and the Upload New Package `<section>` (line 59):

```html
      <!-- Access Codes -->
      <section class="card" id="access-codes-card">
        <div class="card-header">
          <h2>Access Codes</h2>
          <span id="codes-count" class="status-badge empty">0</span>
        </div>
        <div id="codes-list">
          <!-- Populated by JS -->
        </div>
        <div id="codes-empty" class="pkg-empty" hidden>
          <p>No access codes yet.</p>
          <p class="muted">Create a code to share with your pilots.</p>
        </div>
        <div class="codes-add">
          <form id="add-code-form" class="add-code-form">
            <input type="text" id="new-code-input" placeholder="e.g. JLW-7294" maxlength="20" required>
            <button type="submit" class="btn-add-code">Add Code</button>
          </form>
          <div id="codes-error" class="error-msg" hidden></div>
        </div>
      </section>
```

**Step 2: Commit**

```bash
git add web-uploader/index.html
git commit -m "Add Access Codes card to dashboard HTML"
```

---

### Task 6: Add Access Codes CSS

**Files:**
- Modify: `web-uploader/style.css`

**Step 1: Add styles**

Append before the `/* ── RESPONSIVE */` section:

```css
/* ── ACCESS CODES ─────────────────────────────────────────────── */

.codes-add {
  margin-top: 16px;
  padding-top: 16px;
  border-top: 1px solid var(--border-subtle);
}

.add-code-form {
  display: flex;
  gap: 8px;
}

.add-code-form input[type="text"] {
  flex: 1;
  padding: 8px 12px;
  font-size: 14px;
  font-family: var(--font-mono);
  text-transform: uppercase;
}

.btn-add-code {
  padding: 8px 16px;
  font-size: 13px;
  font-weight: 600;
  font-family: var(--font-mono);
  color: var(--text-inverse);
  background: var(--blue);
  border: none;
  border-radius: var(--radius);
  cursor: pointer;
  white-space: nowrap;
  transition: background 0.15s;
}

.btn-add-code:hover {
  background: #4d94f8;
}

.code-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 0;
  border-bottom: 1px solid var(--border-subtle);
}

.code-row:last-child {
  border-bottom: none;
}

.code-info {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.code-value {
  font-size: 15px;
  font-weight: 600;
  font-family: var(--font-mono);
  color: var(--text-primary);
  letter-spacing: 0.04em;
}

.code-apikey {
  font-size: 12px;
  font-family: var(--font-mono);
  color: var(--text-muted);
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 300px;
}

.code-apikey:hover {
  color: var(--text-secondary);
}

.code-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-shrink: 0;
}

.btn-copy {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  font-size: 13px;
  color: var(--text-muted);
  background: none;
  border: 1px solid transparent;
  border-radius: 6px;
  cursor: pointer;
  transition: color 0.15s, background 0.15s;
}

.btn-copy:hover {
  color: var(--blue);
  background: var(--blue-dim);
  border-color: rgba(96, 165, 250, 0.2);
}
```

**Step 2: Commit**

```bash
git add web-uploader/style.css
git commit -m "Add Access Codes card styles"
```

---

### Task 7: Add Access Codes UI Logic to app.js

**Files:**
- Modify: `web-uploader/app.js`

**Step 1: Add DOM refs**

After the existing DOM refs section (after line 39 `const uploadResult`), add:

```javascript
const codesList    = document.getElementById('codes-list');
const codesCount   = document.getElementById('codes-count');
const codesEmpty   = document.getElementById('codes-empty');
const addCodeForm  = document.getElementById('add-code-form');
const newCodeInput = document.getElementById('new-code-input');
const codesError   = document.getElementById('codes-error');
```

**Step 2: Add state variable**

After `let selectedFile = null;` add:

```javascript
let accessCodes = [];
```

**Step 3: Load access codes in loadDashboard**

In the `loadDashboard` function, after the manifest fetch and before `showDashboard()`, add a call to load access codes:

```javascript
async function loadDashboard() {
  clerk.unmountSignIn(document.getElementById('clerk-sign-in'));

  try {
    const manifest = await apiCall('GET', '/api/manifest');
    currentManifest = manifest;

    const codesResp = await apiCall('GET', '/api/access-codes');
    accessCodes = codesResp.codes || [];

    showDashboard();
  } catch (err) {
    console.error('Failed to load dashboard:', err);
    loginView.hidden = false;
    dashboardView.hidden = true;
    var el = document.getElementById('clerk-sign-in');
    el.textContent = 'Failed to load dashboard: ' + err.message;
  }
}
```

**Step 4: Update showDashboard to render codes**

```javascript
function showDashboard() {
  loginView.hidden = true;
  dashboardView.hidden = false;
  renderManifest();
  renderAccessCodes();
}
```

**Step 5: Add renderAccessCodes function**

Add after the `renderManifest` function:

```javascript
function renderAccessCodes() {
  // Clear previous
  while (codesList.firstChild) {
    codesList.removeChild(codesList.firstChild);
  }

  codesCount.textContent = accessCodes.length;
  codesCount.className = 'status-badge ' + (accessCodes.length > 0 ? 'active' : 'empty');

  if (accessCodes.length === 0) {
    codesList.hidden = true;
    codesEmpty.hidden = false;
    return;
  }

  codesList.hidden = false;
  codesEmpty.hidden = true;

  accessCodes.forEach(function (item) {
    var row = document.createElement('div');
    row.className = 'code-row';

    var info = document.createElement('div');
    info.className = 'code-info';

    var codeVal = document.createElement('span');
    codeVal.className = 'code-value';
    codeVal.textContent = item.accessCode;

    var apiKeyVal = document.createElement('span');
    apiKeyVal.className = 'code-apikey';
    apiKeyVal.textContent = maskApiKey(item.apiKey);
    apiKeyVal.title = 'Click to reveal';
    apiKeyVal.addEventListener('click', function () {
      if (apiKeyVal.textContent === item.apiKey) {
        apiKeyVal.textContent = maskApiKey(item.apiKey);
      } else {
        apiKeyVal.textContent = item.apiKey;
      }
    });

    info.appendChild(codeVal);
    info.appendChild(apiKeyVal);

    var actions = document.createElement('div');
    actions.className = 'code-actions';

    var copyBtn = document.createElement('button');
    copyBtn.className = 'btn-copy';
    copyBtn.title = 'Copy access code';
    copyBtn.textContent = '\u2398';
    copyBtn.addEventListener('click', function () {
      navigator.clipboard.writeText(item.accessCode).then(function () {
        copyBtn.textContent = '\u2713';
        setTimeout(function () { copyBtn.textContent = '\u2398'; }, 1500);
      });
    });

    var deleteBtn = document.createElement('button');
    deleteBtn.className = 'btn-icon';
    deleteBtn.title = 'Delete access code';
    deleteBtn.textContent = '\u00D7';
    deleteBtn.addEventListener('click', function () {
      if (confirm('Delete access code "' + item.accessCode + '"? Pilots using this code will lose access.')) {
        deleteCode(item.accessCode);
      }
    });

    actions.appendChild(copyBtn);
    actions.appendChild(deleteBtn);

    row.appendChild(info);
    row.appendChild(actions);
    codesList.appendChild(row);
  });
}

function maskApiKey(key) {
  if (key.length <= 8) return key;
  return key.slice(0, 8) + '\u2026';
}
```

**Step 6: Add form handler and delete function**

Add after the renderAccessCodes function:

```javascript
addCodeForm.addEventListener('submit', async function (e) {
  e.preventDefault();
  codesError.hidden = true;

  var code = newCodeInput.value.trim().toUpperCase();
  if (!code) return;

  try {
    var resp = await apiCall('POST', '/api/access-codes', { accessCode: code });
    accessCodes.push({ accessCode: resp.accessCode, apiKey: resp.apiKey });
    renderAccessCodes();
    newCodeInput.value = '';
  } catch (err) {
    codesError.textContent = err.message;
    codesError.hidden = false;
  }
});

async function deleteCode(accessCode) {
  try {
    await apiCall('DELETE', '/api/access-codes', { accessCode: accessCode });
    accessCodes = accessCodes.filter(function (c) { return c.accessCode !== accessCode; });
    renderAccessCodes();
  } catch (err) {
    codesError.textContent = err.message;
    codesError.hidden = false;
  }
}
```

**Step 7: Commit**

```bash
git add web-uploader/app.js
git commit -m "Add access codes management UI logic"
```

---

### Task 8: Delete Scripts and Clean Up package.json

**Files:**
- Delete: `worker/scripts/generate-api-key.js`
- Delete: `worker/scripts/setup-secrets.js`
- Modify: `worker/package.json`

**Step 1: Delete the scripts**

```bash
rm worker/scripts/generate-api-key.js worker/scripts/setup-secrets.js
```

**Step 2: Remove generate-api-key from package.json scripts**

In `worker/package.json`, remove the `generate-api-key` script line. The scripts section becomes:

```json
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy"
  },
```

**Step 3: Remove worker/scripts directory if empty**

```bash
rmdir worker/scripts 2>/dev/null || true
```

**Step 4: Commit**

```bash
git add -A worker/scripts/ worker/package.json
git commit -m "Remove CLI scripts for access code generation (replaced by admin UI)"
```

---

### Task 9: Deploy and Verify

**Step 1: Deploy worker**

```bash
cd worker && npx wrangler deploy
```

Verify the output shows the `ACCESS_CODES_KV` KV namespace binding.

**Step 2: Deploy web uploader**

```bash
npx wrangler pages deploy web-uploader/ --project-name=jlw-loader-uploader --commit-dirty=true
```

**Step 3: Verify end-to-end**

1. Open https://loader.jlwav.com/ — sign in with Clerk
2. Dashboard shows "Access Codes" card with 0 codes
3. Enter `JLW-7294` in the input, click "Add Code" — code appears in list
4. Click the masked API key — it reveals the full key
5. Click copy button — access code copied to clipboard
6. Click delete button — confirmation appears, code removed
7. Test pilot auth: `curl -X POST https://loader.jlwav.com/api/auth -H "Content-Type: application/json" -d '{"accessCode":"JLW-7294"}'` — should return API key
8. Test API key auth: `curl -H "X-API-Key: <key-from-step-7>" https://loader.jlwav.com/api/manifest` — should return manifest

**Step 4: Delete the old ACCESS_CODES secret**

```bash
cd worker && npx wrangler secret delete ACCESS_CODES
```

(This may already have been deleted — ignore errors.)

**Step 5: Commit any remaining changes and push**

```bash
git add -A && git commit -m "Deploy access code management" && git push
```
