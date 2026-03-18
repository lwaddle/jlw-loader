# JLW Loader — Cloudflare Worker

API gatekeeper for the JLW Loader system. Validates pilot access codes and admin credentials, serves update manifests, and generates presigned R2 URLs for uploads and downloads.

## Architecture

```
iOS App (pilot)              Web Uploader (admin)
     │                              │
     │  X-API-Key                   │  Basic Auth
     ▼                              ▼
┌─────────────────────────────────────────────┐
│            Cloudflare Worker                │
│                                             │
│  /api/auth       - access code → API key    │
│  /api/manifest   - current update manifest  │
│  /api/download   - presigned download URL   │
│  /api/upload-url - presigned upload URL     │
│  /api/manifest   - update manifest (PATCH)  │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│            Cloudflare R2                    │
│                                             │
│  jlw-loader-updates/                        │
│    orgs/jlw-aviation/                       │
│      manifest.json                          │
│      update-2026-03.zip                     │
│    orgs/other-org/                          │
│      manifest.json                          │
│      update-2026-03.zip                     │
└─────────────────────────────────────────────┘
```

## How Authentication Works

There are two separate auth flows — one for pilots, one for admins.

### Pilot Auth (iOS App)

1. Pilot enters a friendly **access code** (e.g. `JLW-7294`) on first launch
2. App sends `POST /api/auth` with the code
3. Worker returns an **API key** which the app stores in the iOS Keychain
4. All subsequent requests include `X-API-Key: <key>` header
5. Worker maps the API key back to an `orgId` and scopes all responses

The access code is human-friendly and shared with all pilots in an org. The API key is a long random string used for machine-to-machine auth.

### Admin Auth (Web Uploader)

1. Admin enters **username + password** in the web uploader
2. Web uploader sends `Authorization: Basic <base64(user:pass)>` with each request
3. Worker validates the password hash and maps the admin to their `orgId`
4. All responses are scoped to the admin's org

Passwords are stored as salted PBKDF2-SHA-256 hashes (100,000 iterations), not plaintext.

## Secrets & Environment Variables

### Non-secret vars (in wrangler.toml)

| Variable | Description | Example |
|---|---|---|
| `R2_BUCKET_NAME` | R2 bucket name | `jlw-loader-updates` |

### Secrets (set via `wrangler secret put`)

| Secret | Description |
|---|---|
| `CF_ACCOUNT_ID` | Cloudflare account ID (from dashboard URL) |
| `ACCESS_CODES` | JSON mapping access codes → `{ orgId, apiKey }` |
| `ADMIN_CREDS` | JSON mapping admin usernames → `{ passwordHash, orgId }` |
| `R2_ACCESS_KEY_ID` | R2 S3-compatible API access key ID |
| `R2_SECRET_ACCESS_KEY` | R2 S3-compatible API secret access key |

### ACCESS_CODES format

```json
{
  "JLW-7294": {
    "orgId": "jlw-aviation",
    "apiKey": "key_a1b2c3d4e5f6..."
  },
  "OTH-5531": {
    "orgId": "other-org",
    "apiKey": "key_x9y8z7w6v5u4..."
  }
}
```

### ADMIN_CREDS format

```json
{
  "loren": {
    "passwordHash": "a1b2c3d4...:e5f6a7b8...",
    "orgId": "jlw-aviation"
  }
}
```

The `passwordHash` is `<salt>:<sha256hex>`. Generate it with:

```sh
npm run hash-password -- "your-password-here"
```

## Quick Start

### Prerequisites

- Node.js 18+
- A Cloudflare account
- An R2 bucket named `jlw-loader-updates`
- An R2 API token (for presigned URLs)

### 1. Install dependencies

```sh
cd worker
npm install
```

### 2. Create the R2 bucket

```sh
wrangler r2 bucket create jlw-loader-updates
```

### 3. Create an R2 API token

Go to: **Cloudflare Dashboard → R2 → Manage R2 API Tokens → Create API Token**

- Permissions: **Object Read & Write**
- Scope: `jlw-loader-updates` bucket only
- Save the Access Key ID and Secret Access Key

### 4. Generate credentials

The interactive setup script walks you through everything:

```sh
node scripts/setup-secrets.js
```

Or generate individually:

```sh
# Generate an API key for a new org's ACCESS_CODES entry
npm run generate-api-key

# Hash a password for a new admin's ADMIN_CREDS entry
npm run hash-password -- "the-admin-password"
```

### 5. Set secrets

```sh
wrangler secret put CF_ACCOUNT_ID
wrangler secret put ACCESS_CODES
wrangler secret put ADMIN_CREDS
wrangler secret put R2_ACCESS_KEY_ID
wrangler secret put R2_SECRET_ACCESS_KEY
```

### 6. Set your account ID

Edit `wrangler.toml` and uncomment the `CF_ACCOUNT_ID` line, or set it as a secret (step 5 covers this).

### 7. Deploy

```sh
npm run deploy
```

### 8. Local development

```sh
npm run dev
```

This starts a local dev server. For local R2 access, Wrangler uses a local emulated bucket.

## Adding a New Organization

**Total time: ~5 minutes. No code changes. No redeployment.**

1. **Pick an org ID** — lowercase, hyphenated (e.g. `acme-air`)

2. **Pick a friendly access code** — something easy to communicate verbally (e.g. `ACM-4419`)

3. **Generate an API key:**
   ```sh
   npm run generate-api-key
   ```

4. **Generate admin password hash:**
   ```sh
   npm run hash-password -- "the-admin-password"
   ```

5. **Update the ACCESS_CODES secret** — add the new entry to the JSON:
   ```json
   {
     "existing entries...": "...",
     "ACM-4419": { "orgId": "acme-air", "apiKey": "key_<generated>" }
   }
   ```
   ```sh
   wrangler secret put ACCESS_CODES
   # Paste the full updated JSON
   ```

6. **Update the ADMIN_CREDS secret** — add the new admin:
   ```json
   {
     "existing entries...": "...",
     "acme-admin": { "passwordHash": "<generated>", "orgId": "acme-air" }
   }
   ```
   ```sh
   wrangler secret put ADMIN_CREDS
   # Paste the full updated JSON
   ```

7. **Send credentials out of band:**
   - Pilots get the access code (`ACM-4419`)
   - Admin gets their username + password

The org's R2 path (`orgs/acme-air/`) is created automatically on first upload.

## API Reference

### POST /api/auth

Exchange an access code for an API key. Called once on first app launch.

**Request:**
```json
{ "accessCode": "JLW-7294" }
```

**Response (200):**
```json
{ "apiKey": "key_a1b2c3...", "orgId": "jlw-aviation" }
```

**Error (401):**
```json
{ "error": "Access code not recognized. Contact your administrator." }
```

---

### GET /api/manifest

Get the current update manifest for the caller's org.

**Auth:** `X-API-Key` header (pilot) or `Authorization: Basic` (admin)

**Response (200):**
```json
{
  "orgId": "jlw-aviation",
  "packageFilename": "update-2026-03.zip",
  "packageSizeBytes": 187234816,
  "packageChecksum": "sha256:abc123...",
  "uploadedAt": "2026-03-17T16:30:00Z"
}
```

**Response (200, no package yet):**
```json
{ "orgId": "jlw-aviation", "message": "No update package uploaded yet" }
```

---

### POST /api/download

Get a presigned URL to download the current update ZIP.

**Auth:** `X-API-Key` header

**Response (200):**
```json
{
  "downloadUrl": "https://...r2.cloudflarestorage.com/...",
  "filename": "update-2026-03.zip",
  "expiresIn": 900
}
```

---

### POST /api/upload-url

Get a presigned URL to upload a new update ZIP directly to R2.

**Auth:** `Authorization: Basic`

**Request:**
```json
{ "filename": "update-2026-03.zip" }
```

**Response (200):**
```json
{
  "uploadUrl": "https://...r2.cloudflarestorage.com/...",
  "key": "orgs/jlw-aviation/update-2026-03.zip",
  "expiresIn": 900
}
```

---

### PATCH /api/manifest

Update the manifest after uploading a new package.

**Auth:** `Authorization: Basic`

**Request:**
```json
{
  "packageFilename": "update-2026-03.zip",
  "packageSizeBytes": 187234816,
  "packageChecksum": "sha256:abc123...",
  "uploadedAt": "2026-03-17T16:30:00Z"
}
```

Note: `orgId` is set automatically from the admin's credentials — any client-supplied `orgId` is overwritten.

**Response (200):**
```json
{ "success": true, "orgId": "jlw-aviation" }
```

## R2 Bucket Structure

```
jlw-loader-updates/
  orgs/
    jlw-aviation/
      manifest.json          ← current cycle metadata
      update-2026-03.zip     ← compressed update package
    other-org/
      manifest.json
      update-2026-03.zip
```

Each org is fully isolated. The Worker enforces this at the auth layer — a pilot or admin can only access their own org's path.

## Security Notes

- **Passwords are salted + hashed** — PBKDF2-SHA-256 with 100,000 iterations and a random 16-byte salt. Plaintext passwords are never stored.
- **API key lookups use constant-time comparison** — prevents timing attacks.
- **Admin orgId is server-enforced** — the manifest PATCH endpoint overwrites any client-supplied orgId with the admin's actual org. An admin cannot write to another org's path.
- **Filename validation** — upload filenames are checked for path traversal characters.
- **Presigned URLs expire in 15 minutes** — limits the window if a URL is leaked.
- **All secrets are encrypted at rest** — Cloudflare manages secret encryption. Secrets never appear in logs or the dashboard after creation.
