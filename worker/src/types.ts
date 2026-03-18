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
