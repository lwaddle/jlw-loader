# Fixes + Single Access Code Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix two multi-org bugs (stale UserDefaults on org switch, no refresh after 401 removeOrg) and simplify access codes to a single auto-generated code per org.

**Architecture:** iOS fixes are small changes to AppState. Backend gets a new `regenerateAccessCode` function and `/api/access-codes/regenerate` endpoint. Web uploader replaces the multi-code UI with a single-code display + regenerate button.

**Tech Stack:** Swift/SwiftUI (iOS), TypeScript/Cloudflare Worker (backend), Vanilla JS/CSS/HTML (web uploader)

---

### Task 1: Fix — Clear UserDefaults on org switch

**Files:**
- Modify: `ios/JLWLoader/AppState.swift:89-103` (switchOrg method)

**Step 1: Clear org-specific UserDefaults in switchOrg**

In `AppState.swift`, in the `switchOrg(to:)` method, add UserDefaults clearing after `cancelDownload()` and before `deleteExistingPackage`:

```swift
func switchOrg(to orgId: String) async {
    guard orgId != activeOrgId,
          credentials.contains(where: { $0.orgId == orgId }) else { return }

    activeOrgId = orgId
    try? KeychainService.setActiveOrgId(orgId)

    // Clear current state and check for updates with new org
    manifest = nil
    cancelDownload()

    // Clear org-specific timestamps so new org starts fresh
    UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.lastDownloadedAt)
    UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.lastDownloadedFilename)
    UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.lastTransferredAt)
    UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.lastTransferredFilename)

    if hasLocalPackage() {
        await downloadManager.deleteExistingPackage()
    }
    await checkForUpdates()
}
```

**Step 2: Run tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add ios/JLWLoader/AppState.swift
git commit -m "fix: clear UserDefaults timestamps on org switch"
```

---

### Task 2: Fix — Auto-check after removeOrg on 401

**Files:**
- Modify: `ios/JLWLoader/AppState.swift:159-160` (401 handler in checkForUpdates)

**Step 1: Add recursive checkForUpdates after removeOrg**

In `checkForUpdates()`, update the 401 catch block:

```swift
} catch let error as APIError where error.isUnauthorized {
    removeOrg(cred.orgId)
    if isAuthenticated {
        await checkForUpdates()
    }
}
```

**Step 2: Run tests**

Run: `xcodebuild test -project ios/JLWLoader.xcodeproj -scheme JLWLoader -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add ios/JLWLoader/AppState.swift
git commit -m "fix: auto-check updates after 401 removes active org"
```

---

### Task 3: Backend — Add access code generation and regenerate endpoint

**Files:**
- Modify: `worker/src/auth.ts` (add generateAccessCode and regenerateAccessCode functions)
- Modify: `worker/src/index.ts` (add POST /api/access-codes/regenerate handler)

**Step 1: Add generateAccessCode function to auth.ts**

Add after the existing `generateApiKey` function (after line 40):

```typescript
const ACCESS_CODE_CHARSET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export function generateAccessCodeString(): string {
  const bytes = new Uint8Array(7);
  crypto.getRandomValues(bytes);
  const chars = Array.from(bytes).map(
    (b) => ACCESS_CODE_CHARSET[b % ACCESS_CODE_CHARSET.length]
  );
  return chars.slice(0, 3).join('') + '-' + chars.slice(3).join('');
}
```

**Step 2: Add regenerateAccessCode function to auth.ts**

Add after `deleteAccessCode`:

```typescript
export async function regenerateAccessCode(
  kv: KVNamespace,
  orgId: string,
  orgName?: string,
): Promise<{ accessCode: string; apiKey: string }> {
  // Delete all existing codes for this org
  const existingCodes = await listAccessCodes(kv, orgId);
  for (const code of existingCodes) {
    await kv.delete(`code:${code}`);
  }
  await saveOrgIndex(kv, orgId, []);

  // Generate a new unique code (retry on collision)
  let accessCode: string;
  let attempts = 0;
  do {
    accessCode = generateAccessCodeString();
    const collision = await kv.get(`code:${accessCode}`);
    if (collision === null) break;
    attempts++;
  } while (attempts < 10);

  if (attempts >= 10) {
    throw new Error('GENERATION_FAILED');
  }

  const apiKey = await createAccessCode(kv, orgId, accessCode, orgName);
  return { accessCode, apiKey };
}
```

**Step 3: Add POST /api/access-codes/regenerate handler to index.ts**

In `worker/src/index.ts`, add a new case in the switch statement, after the `/api/access-codes` case:

```typescript
case '/api/access-codes/regenerate':
  if (request.method === 'POST') { response = await handleRegenerateAccessCode(request, env); break; }
  response = errorResponse('Not found', 404); break;
```

Add the handler function:

```typescript
async function handleRegenerateAccessCode(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  try {
    const result = await regenerateAccessCode(env.ACCESS_CODES_KV, admin.orgId, admin.orgName);
    return json({ accessCode: result.accessCode });
  } catch (err) {
    if (err instanceof Error && err.message === 'GENERATION_FAILED') {
      return errorResponse('Failed to generate unique access code. Please try again.', 500);
    }
    throw err;
  }
}
```

Update the import at the top of index.ts to include `regenerateAccessCode`:

```typescript
import {
  findByAccessCode,
  findOrgByApiKey,
  listAccessCodes,
  createAccessCode,
  deleteAccessCode,
  regenerateAccessCode,
} from './auth';
```

**Step 4: Build**

Run: `cd worker && npm run build`
Expected: No TypeScript errors

**Step 5: Commit**

```bash
git add worker/src/auth.ts worker/src/index.ts
git commit -m "feat: add access code generation and regenerate endpoint"
```

---

### Task 4: Web uploader — Replace multi-code UI with single-code display

**Files:**
- Modify: `web-uploader/index.html` (replace access codes card HTML)
- Modify: `web-uploader/app.js` (replace renderAccessCodes, add/delete handlers with single-code logic)
- Modify: `web-uploader/style.css` (update access code styles)

**Step 1: Replace access codes HTML in index.html**

Replace the entire Access Codes section (the `<section class="card" id="access-codes-card">` block) with:

```html
<!-- Access Code -->
<section class="card" id="access-code-card">
  <div class="card-header">
    <h2>Access Code</h2>
  </div>
  <div id="access-code-display" class="access-code-display" hidden>
    <div class="access-code-row">
      <span id="access-code-value" class="access-code-value"></span>
      <button id="copy-code-btn" class="btn-copy" title="Copy access code">&#x2398;</button>
    </div>
    <p class="muted">Share this code with your pilots to grant access.</p>
  </div>
  <div id="access-code-loading" class="pkg-empty">
    <p>Loading access code...</p>
  </div>
  <div class="access-code-actions">
    <button id="regenerate-code-btn" class="btn-regenerate">Generate New Code</button>
  </div>
  <div id="access-code-error" class="error-msg" hidden></div>
</section>
```

**Step 2: Update DOM refs in app.js**

Remove the old DOM refs for codesList, codesCount, codesEmpty, addCodeForm, newCodeInput, codesError. Replace with new ones. In the DOM REFS section, remove:

```javascript
const codesList    = document.getElementById('codes-list');
const codesCount   = document.getElementById('codes-count');
const codesEmpty   = document.getElementById('codes-empty');
const addCodeForm  = document.getElementById('add-code-form');
const newCodeInput = document.getElementById('new-code-input');
const codesError   = document.getElementById('codes-error');
```

And add:

```javascript
const accessCodeDisplay = document.getElementById('access-code-display');
const accessCodeValue   = document.getElementById('access-code-value');
const accessCodeLoading = document.getElementById('access-code-loading');
const accessCodeError   = document.getElementById('access-code-error');
const copyCodeBtn       = document.getElementById('copy-code-btn');
const regenerateCodeBtn = document.getElementById('regenerate-code-btn');
```

**Step 3: Replace renderAccessCodes and related functions in app.js**

Remove the entire `renderAccessCodes` function, the `add-code-btn` event listener, and the `deleteCode` function. Also remove the `accessCodes` state variable at the top.

Replace with:

```javascript
// ── ACCESS CODE ──────────────────────────────────────────────────

var currentAccessCode = null;

async function loadAccessCode() {
  accessCodeDisplay.hidden = true;
  accessCodeLoading.hidden = false;
  accessCodeError.hidden = true;

  try {
    var codesResp = await apiCall('GET', '/api/access-codes');
    var codes = codesResp.codes || [];

    if (codes.length === 1) {
      currentAccessCode = codes[0].accessCode;
      showAccessCode(currentAccessCode);
    } else {
      // No codes or multiple codes — regenerate to get a single fresh one
      await regenerateCode(true);
    }
  } catch (err) {
    accessCodeLoading.hidden = true;
    accessCodeError.textContent = 'Failed to load access code: ' + err.message;
    accessCodeError.hidden = false;
  }
}

function showAccessCode(code) {
  accessCodeValue.textContent = code;
  accessCodeDisplay.hidden = false;
  accessCodeLoading.hidden = true;
}

async function regenerateCode(silent) {
  accessCodeError.hidden = true;
  if (!silent) {
    accessCodeDisplay.hidden = true;
    accessCodeLoading.hidden = false;
  }

  try {
    var resp = await apiCall('POST', '/api/access-codes/regenerate');
    currentAccessCode = resp.accessCode;
    showAccessCode(currentAccessCode);
  } catch (err) {
    accessCodeLoading.hidden = true;
    accessCodeError.textContent = 'Failed to generate code: ' + err.message;
    accessCodeError.hidden = false;
  }
}

copyCodeBtn.addEventListener('click', function () {
  if (!currentAccessCode) return;
  navigator.clipboard.writeText(currentAccessCode).then(function () {
    copyCodeBtn.textContent = '\u2713';
    setTimeout(function () { copyCodeBtn.textContent = '\u2398'; }, 1500);
  });
});

regenerateCodeBtn.addEventListener('click', function () {
  if (confirm('Generate a new access code?\n\nThe current code will stop working. You will need to share the new code with your pilots.')) {
    regenerateCode(false);
  }
});
```

**Step 4: Update loadDashboard to call loadAccessCode instead of fetching codes**

In the `loadDashboard` function, replace:

```javascript
const codesResp = await apiCall('GET', '/api/access-codes');
accessCodes = codesResp.codes || [];
```

with:

```javascript
await loadAccessCode();
```

And in `showDashboard`, remove the call to `renderAccessCodes()`.

**Step 5: Add CSS for single access code display**

In `web-uploader/style.css`, remove or replace the old `.codes-add`, `.add-code-form`, `.code-row`, `.code-value`, `.code-actions` styles. Add:

```css
.access-code-display {
  text-align: center;
  padding: 16px 0;
}

.access-code-row {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  margin-bottom: 12px;
}

.access-code-value {
  font-size: 24px;
  font-weight: 600;
  font-family: var(--font-mono);
  color: var(--text-primary);
  letter-spacing: 0.08em;
}

.access-code-actions {
  margin-top: 16px;
  padding-top: 16px;
  border-top: 1px solid var(--border-subtle);
}

.btn-regenerate {
  width: 100%;
  padding: 8px 16px;
  font-size: 13px;
  font-weight: 500;
  font-family: var(--font-mono);
  color: var(--text-secondary);
  background: none;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  cursor: pointer;
  transition: color 0.15s, border-color 0.15s;
}

.btn-regenerate:hover {
  color: var(--text-primary);
  border-color: var(--text-muted);
}
```

**Step 6: Verify in browser**

1. Sign in as admin
2. Access code card should show a single auto-generated code like `JKR-7M4P`
3. Copy button works
4. "Generate New Code" shows confirmation, then generates and displays new code
5. Old codes should have been cleaned up

**Step 7: Commit**

```bash
git add web-uploader/index.html web-uploader/app.js web-uploader/style.css
git commit -m "feat: replace multi-code UI with single auto-generated access code"
```
