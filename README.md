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
        │  Basic auth                       │  API key
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
node scripts/setup-secrets.js   # interactive credential setup
wrangler r2 bucket create jlw-loader-updates
# set secrets as prompted by setup script
npm run deploy
```

See [`worker/README.md`](worker/README.md) for full setup, API reference, and how to add new organizations.

### 2. Deploy the Web Uploader

```sh
cd web-uploader
```

Edit `config.js` — set `workerUrl` for your deployment:

```js
const CONFIG = {
  // Same-origin (Pages + Worker share loader.jlwav.com):
  workerUrl: "",
  // Or a separate Workers subdomain:
  // workerUrl: "https://jlw-loader-worker.your-subdomain.workers.dev",
};
```

Then deploy to Cloudflare Pages:

```sh
# Option A: Wrangler CLI
npx wrangler pages deploy . --project-name=jlw-loader-admin

# Option B: Connect a Git repo in the Cloudflare dashboard
#   Build command: (none)
#   Output directory: web-uploader
```

No build step — Pages serves the static files directly.

### 3. Upload Your First Package

1. Open the web uploader URL in a browser
2. Log in with the admin credentials you created during setup
3. Fill in the version, cycle number, and release date
4. Drop your update ZIP file and click Upload

### 4. iOS App (Coming Later)

The iOS app is Phase 2. When built, pilots will:
1. Enter their access code once on first launch
2. See when a new update is available
3. Download it with one tap
4. Connect a USB drive and tap Transfer

## Multi-Tenancy

Each organization gets its own isolated space — separate access code, admin credentials, and R2 storage path. Adding a new org takes ~5 minutes and requires no code changes. See the [Worker README](worker/README.md#adding-a-new-organization) for the step-by-step process.

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
