/**
 * Cloudflare Worker environment bindings.
 *
 * Secrets (set via `wrangler secret put <NAME>`):
 *   ACCESS_CODES         – JSON mapping friendly access codes to { orgId, apiKey }
 *   ADMIN_CREDS          – JSON mapping admin usernames to { passwordHash, orgId }
 *   R2_ACCESS_KEY_ID     – R2 S3-compatible API access key
 *   R2_SECRET_ACCESS_KEY – R2 S3-compatible API secret key
 *
 * Vars (set in wrangler.toml):
 *   CF_ACCOUNT_ID  – Cloudflare account ID (used for R2 S3 endpoint)
 *   R2_BUCKET_NAME – R2 bucket name
 */
export interface Env {
  // R2 binding (native, for direct reads/writes)
  UPDATES_BUCKET: R2Bucket;

  // Secrets
  ACCESS_CODES: string;
  ADMIN_CREDS: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;

  // Vars
  CF_ACCOUNT_ID: string;
  R2_BUCKET_NAME: string;
}

/**
 * ACCESS_CODES JSON schema:
 * {
 *   "JLW-7294": { "orgId": "jlw-aviation", "apiKey": "key_a1b2c3d4..." },
 *   "OTH-5531": { "orgId": "other-org",    "apiKey": "key_x9y8z7w6..." }
 * }
 */
export interface AccessCodeEntry {
  orgId: string;
  apiKey: string;
}

/**
 * ADMIN_CREDS JSON schema:
 * {
 *   "loren": { "passwordHash": "<salt>:<sha256hex>", "orgId": "jlw-aviation" }
 * }
 *
 * Use `scripts/hash-password.js` to generate the passwordHash value.
 */
export interface AdminCredEntry {
  passwordHash: string;
  orgId: string;
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
