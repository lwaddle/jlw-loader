# Access Code Management via Admin Dashboard

## Context

Pilot auth uses access codes exchanged for API keys. Currently, codes are managed manually via the `ACCESS_CODES` Wrangler secret and the `generate-api-key` CLI script. This design adds a UI to the admin dashboard for creating, viewing, and deleting access codes, backed by Cloudflare KV instead of a secret.

## Decision

Keep the existing access-code-based pilot auth (no Clerk for pilots). Move storage from the `ACCESS_CODES` env var to a KV namespace. Add CRUD endpoints and a dashboard UI for managing codes.

**Why not Clerk for pilots?** The app serves 3 pilots at one organization. Clerk would add account management overhead for a "type a code once and forget" use case.

## Data Model

**KV namespace:** `ACCESS_CODES_KV`

Each access code is stored as two KV entries:

1. **Code lookup** (used by pilot auth and API key validation):
   - Key: `code:<access_code>` (e.g., `code:JLW-7294`)
   - Value: `{ "orgId": "jlw-aviation", "apiKey": "key_abc123..." }`

2. **Org index** (used to list codes for an org in the admin UI):
   - Key: `org:<orgId>:codes` (e.g., `org:jlw-aviation:codes`)
   - Value: `["JLW-7294", "JLW-8812"]`

API keys are generated server-side using `crypto.getRandomValues()` — 32 random bytes, hex-encoded, prefixed with `key_`.

## API Endpoints

Three new admin-only endpoints (Clerk Bearer token required):

### `GET /api/access-codes`
List all access codes for the admin's org.

Response (200):
```json
{ "codes": [{ "accessCode": "JLW-7294", "apiKey": "key_abc..." }] }
```

### `POST /api/access-codes`
Create a new access code. Admin provides the friendly code, worker generates the API key.

Request:
```json
{ "accessCode": "JLW-7294" }
```

Response (201):
```json
{ "accessCode": "JLW-7294", "apiKey": "key_abc..." }
```

Returns 409 if the code already exists.

### `DELETE /api/access-codes`
Delete an access code.

Request:
```json
{ "accessCode": "JLW-7294" }
```

Response (200):
```json
{ "success": true }
```

Returns 404 if the code does not exist.

### Existing endpoints (modified)

- `POST /api/auth` — pilot code exchange reads from KV instead of env var
- `X-API-Key` validation — reads from KV instead of env var

## Admin Dashboard UI

New "Access Codes" card on the dashboard, between Current Package and Upload sections:

- **Header:** "Access Codes" with a count badge
- **Table:** Each row shows access code and API key (masked by default, click to reveal)
- **Add:** Inline form — admin types a friendly code, submits, new code + generated key appears
- **Delete:** Per-row button with confirmation prompt
- **Copy:** Per-row button to copy access code to clipboard (for texting to a pilot)

Same vanilla JS approach as existing UI. No frameworks.

## Validation

- Access code: non-empty string, trimmed, max 20 characters
- Duplicate codes: 409 Conflict on create
- Non-existent code on delete: 404
- KV failures: 500 with generic error message

## Migration

Since no access codes have been distributed yet:
1. Create KV namespace via `wrangler kv namespace create ACCESS_CODES_KV`
2. Add KV binding to `wrangler.toml`
3. Remove `ACCESS_CODES` from `Env` interface and auth functions
4. Rewrite auth functions to read from KV
5. Delete `ACCESS_CODES` secret via `wrangler secret delete ACCESS_CODES`
6. Delete `worker/scripts/generate-api-key.js` and `worker/scripts/setup-secrets.js`

## Files Modified

| File | Change |
|------|--------|
| `worker/wrangler.toml` | Add KV namespace binding, remove ACCESS_CODES secret comment |
| `worker/src/types.ts` | Remove ACCESS_CODES from Env, add KV binding, remove AccessCodeEntry (move to auth.ts or inline) |
| `worker/src/auth.ts` | Rewrite to read from KV instead of parsing JSON env var |
| `worker/src/index.ts` | Add access-codes CRUD endpoints, update auth calls for KV |
| `worker/package.json` | Remove generate-api-key script |
| `worker/scripts/generate-api-key.js` | Delete |
| `worker/scripts/setup-secrets.js` | Delete |
| `web-uploader/index.html` | Add Access Codes card to dashboard |
| `web-uploader/app.js` | Add access code CRUD UI logic |
