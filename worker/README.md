# JLW Loader — Cloudflare Worker

API gatekeeper for the JLW Loader system. Validates pilot access codes and admin credentials, serves update manifests, and generates presigned R2 URLs for uploads and downloads.

## Architecture

```
iOS App (pilot)              Web Uploader (admin)
     │                              │
     │  X-API-Key                   │  Clerk JWT
     ▼                              ▼
┌─────────────────────────────────────────────┐
│            Cloudflare Worker                │
│                                             │
│  /api/auth         - access code → API key  │
│  /api/manifest     - current update manifest│
│  /api/download     - presigned download URL │
│  /api/upload-url   - presigned upload URL   │
│  /api/manifest     - update manifest (PATCH)│
│  /api/access-codes - manage access codes    │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│            Cloudflare R2 + KV               │
│                                             │
│  R2: jlw-loader-updates/                    │
│    orgs/jlw-aviation/manifest.json          │
│    orgs/jlw-aviation/update-2026-03.zip     │
│                                             │
│  KV: ACCESS_CODES_KV                        │
│    code:JLW-7294 → { orgId, apiKey }        │
│    org:jlw-aviation:codes → ["JLW-7294"]    │
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

The access code is human-friendly and shared with all pilots in an org. The API key is a long random string used for machine-to-machine auth. Access codes are managed via the admin dashboard.

### Admin Auth (Web Uploader)

1. Admin signs in via **Clerk** (email/password or SSO)
2. Web uploader includes `Authorization: Bearer <clerk_jwt>` with each request
3. Worker verifies the JWT via Clerk's JWKS endpoint and reads the `org_slug` claim
4. All responses are scoped to the admin's Clerk organization

Admin accounts are managed in Clerk. Each Clerk organization's slug must match the orgId used in R2 paths and access codes.

## Environment Variables & Bindings

### Non-secret vars (in wrangler.toml)

| Variable | Description | Example |
|---|---|---|
| `R2_BUCKET_NAME` | R2 bucket name | `jlw-loader-updates` |
| `CLERK_ISSUER` | Clerk Frontend API URL (JWT issuer) | `https://clerk.loader.jlwav.com` |
| `CLERK_JWKS_URL` | Clerk JWKS endpoint | `https://clerk.loader.jlwav.com/.well-known/jwks.json` |
| `CF_ACCOUNT_ID` | Cloudflare account ID | `6182b140...` |

### Bindings (in wrangler.toml)

| Binding | Type | Description |
|---|---|---|
| `UPDATES_BUCKET` | R2 Bucket | Stores manifests and update ZIPs |
| `ACCESS_CODES_KV` | KV Namespace | Stores pilot access codes and API keys |

### Secrets (set via `wrangler secret put`)

| Secret | Description |
|---|---|
| `R2_ACCESS_KEY_ID` | R2 S3-compatible API access key ID |
| `R2_SECRET_ACCESS_KEY` | R2 S3-compatible API secret access key |

### KV Data Model

Access codes are stored in the `ACCESS_CODES_KV` namespace with two key patterns:

**Code lookup** — used by pilot auth:
- Key: `code:<accessCode>` (e.g., `code:JLW-7294`)
- Value: `{ "orgId": "jlw-aviation", "apiKey": "key_a1b2c3..." }`

**Org index** — used to list codes in the admin UI:
- Key: `org:<orgId>:codes` (e.g., `org:jlw-aviation:codes`)
- Value: `["JLW-7294", "JLW-8812"]`

## Quick Start

### Prerequisites

- Node.js 18+
- A Cloudflare account
- A Clerk account with Organizations enabled
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

### 4. Create the KV namespace

```sh
wrangler kv namespace create ACCESS_CODES_KV
```

Copy the namespace ID from the output and add it to `wrangler.toml`.

### 5. Set up Clerk

1. Create a Clerk app at [clerk.com](https://clerk.com)
2. Enable Organizations
3. Create an organization with slug matching your orgId (e.g., `jlw-aviation`)
4. Update `CLERK_ISSUER` and `CLERK_JWKS_URL` in `wrangler.toml` with your Clerk Frontend API URL

### 6. Set secrets

```sh
wrangler secret put R2_ACCESS_KEY_ID
wrangler secret put R2_SECRET_ACCESS_KEY
```

### 7. Deploy

```sh
npm run deploy
```

### 8. Create access codes

Sign in to the web uploader and use the Access Codes section to create codes for your pilots.

### 9. Local development

```sh
npm run dev
```

This starts a local dev server. For local R2 access, Wrangler uses a local emulated bucket.

## Adding a New Organization

1. **Create a Clerk organization** with a slug matching the desired orgId (e.g., `acme-air`)
2. **Invite admin users** to the organization in Clerk
3. **Sign in** to the web uploader — the admin will see the new org's dashboard
4. **Create access codes** via the Access Codes section in the dashboard
5. **Send access codes** to pilots out of band (text, email, etc.)

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

**Auth:** `X-API-Key` header (pilot) or `Authorization: Bearer` (admin)

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

**Auth:** `Authorization: Bearer` (Clerk JWT)

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

**Auth:** `Authorization: Bearer` (Clerk JWT)

**Request:**
```json
{
  "packageFilename": "update-2026-03.zip",
  "packageSizeBytes": 187234816,
  "packageChecksum": "sha256:abc123...",
  "uploadedAt": "2026-03-17T16:30:00Z"
}
```

Note: `orgId` is set automatically from the admin's Clerk organization — any client-supplied `orgId` is overwritten.

**Response (200):**
```json
{ "success": true, "orgId": "jlw-aviation" }
```

---

### GET /api/access-codes

List all access codes for the admin's org.

**Auth:** `Authorization: Bearer` (Clerk JWT)

**Response (200):**
```json
{
  "codes": [
    { "accessCode": "JLW-7294", "apiKey": "key_a1b2c3..." }
  ]
}
```

---

### POST /api/access-codes

Create a new access code. The API key is generated server-side.

**Auth:** `Authorization: Bearer` (Clerk JWT)

**Request:**
```json
{ "accessCode": "JLW-7294" }
```

**Response (201):**
```json
{ "accessCode": "JLW-7294", "apiKey": "key_a1b2c3..." }
```

**Error (409):**
```json
{ "error": "Access code already exists" }
```

---

### DELETE /api/access-codes

Delete an access code. Pilots using this code will lose access.

**Auth:** `Authorization: Bearer` (Clerk JWT)

**Request:**
```json
{ "accessCode": "JLW-7294" }
```

**Response (200):**
```json
{ "success": true }
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

- **Admin auth via Clerk** — JWTs verified against Clerk's JWKS endpoint. No passwords stored in the project.
- **API key lookups use constant-time comparison** — prevents timing attacks.
- **Admin orgId is server-enforced** — the manifest PATCH endpoint overwrites any client-supplied orgId with the admin's actual org. An admin cannot write to another org's path.
- **Filename validation** — upload filenames are checked for path traversal characters.
- **Presigned URLs expire in 15 minutes** — limits the window if a URL is leaked.
- **Access codes stored in KV** — managed via the admin dashboard, no manual secret management needed.
