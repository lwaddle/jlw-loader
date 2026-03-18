# JLW Loader

Avionics database update distribution system for JLW Aviation. Pilots receive Rockwell Collins Pro Line 21 / DBU-5000 updates via an iOS app and transfer them to a USB drive — no laptop required.

## How It Works

```
 Admin (desktop browser)              Pilot (iPhone)
       │                                    │
       │  uploads ZIP                       │  enters access code once
       ▼                                    ▼
 ┌──────────────┐                    ┌──────────────┐
 │ Web Uploader │                    │  iOS App     │
 │ (static site)│                    │  (SwiftUI)   │
 └──────┬───────┘                    └──────┬───────┘
        │                                   │
        │  Clerk JWT                        │  API key
        ▼                                   ▼
 ┌─────────────────────────────────────────────────┐
 │              Cloudflare Worker                  │
 │         (validates credentials,                 │
 │          scopes everything to org)              │
 └────────────────────┬────────────────────────────┘
                      │
                      ▼
 ┌─────────────────────────────────────────────────┐
 │              Cloudflare R2                      │
 │    /orgs/jlw-aviation/manifest.json             │
 │    /orgs/jlw-aviation/update-2026-03.zip        │
 └─────────────────────────────────────────────────┘
```

1. **Admin** zips the update files and uploads via the web uploader
2. **Worker** stores the ZIP in R2 and updates the manifest
3. **Pilot** opens the iOS app, downloads the update, plugs in a USB drive, taps transfer
4. **App** wipes the drive and writes the exact DBU-5000 file structure

## Project Structure

```
jlw-loader/
  worker/              Cloudflare Worker (API gatekeeper)
  web-uploader/        Static HTML/JS admin page (Cloudflare Pages)
  EXAMPLE_DATA_LOAD/   Ground-truth USB drive file structure (not tracked in git)
  JLW-LOADER-SPEC.md   Full technical specification
```

| Component | Tech | Hosting | Status |
|---|---|---|---|
| Worker | TypeScript | Cloudflare Workers | Built |
| Web Uploader | HTML + vanilla JS | Cloudflare Pages | Built |
| iOS App | SwiftUI | App Store | Not started |

## Quick Start

### 1. Deploy the Worker

```sh
cd worker
npm install
wrangler r2 bucket create jlw-loader-updates
wrangler kv namespace create ACCESS_CODES_KV
# Add the KV namespace ID to wrangler.toml
wrangler secret put R2_ACCESS_KEY_ID
wrangler secret put R2_SECRET_ACCESS_KEY
npm run deploy
```

See [`worker/README.md`](worker/README.md) for full setup, API reference, and how to add new organizations.

### 2. Set up Clerk

1. Create a Clerk app at [clerk.com](https://clerk.com)
2. Create an organization with a slug matching your orgId (e.g., `jlw-aviation`)
3. Invite admin users to the organization
4. Update `CLERK_ISSUER` and `CLERK_JWKS_URL` in `worker/wrangler.toml`
5. Update `clerkPublishableKey` in `web-uploader/config.js`

### 3. Deploy the Web Uploader

```sh
cd web-uploader
```

Edit `config.js` — set `workerUrl` and `clerkPublishableKey`:

```js
const CONFIG = {
  // Same-origin (Pages + Worker share loader.jlwav.com):
  workerUrl: "",
  clerkPublishableKey: "pk_live_xxxx",
};
```

Then deploy to Cloudflare Pages:

```sh
npx wrangler pages deploy . --project-name=jlw-loader-admin
```

No build step — Pages serves the static files directly.

### 4. Upload Your First Package

1. Open the web uploader URL in a browser
2. Sign in with your Clerk account
3. Create a pilot access code in the Access Codes section
4. Drop your update ZIP file and click Upload

### 5. iOS App (Coming Later)

The iOS app is Phase 2. When built, pilots will:
1. Enter their access code once on first launch
2. See when a new update is available
3. Download it with one tap
4. Connect a USB drive and tap Transfer

## Multi-Tenancy

Each organization gets its own isolated space — separate access codes, Clerk organization, and R2 storage path. Adding a new org requires creating a Clerk organization and managing access codes through the admin dashboard. See the [Worker README](worker/README.md#adding-a-new-organization) for details.

## USB Drive File Structure

The `EXAMPLE_DATA_LOAD/` folder (kept locally, not in git) contains the exact file layout the DBU-5000 expects:

```
USB Drive Root/
  E-Maps/           Electronic charts (27 .LUP files + metadata)
  J7_Americas/      Nav database (26 data files + metadata)
  Jeppesen_Disk_*/  Jeppesen chart data (19 files in Charts/)
  XM_GWx/           XM weather graphics (20 data files + metadata)
```

The iOS app will recreate this exact structure on every USB transfer.

## Spec

The full technical specification is in [`JLW-LOADER-SPEC.md`](JLW-LOADER-SPEC.md). It covers architecture, auth model, iOS app states, error handling, and build order.
