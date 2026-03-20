/**
 * JLW Loader — Cloudflare Worker
 *
 * API gatekeeper for the JLW Loader system. Handles:
 *   - Pilot auth: access code → API key exchange
 *   - Manifest: serve current update manifest per org
 *   - Download: presigned R2 URLs for the iOS app
 *   - Upload: presigned R2 URLs for the web uploader
 *   - Manifest update: admin writes new manifest after upload
 *   - Access code management: admin CRUD for pilot access codes
 *
 * All endpoints are scoped to an organization via auth credentials.
 * See README.md for setup and deployment instructions.
 */

import { Env } from './types';
import {
  findByAccessCode,
  findOrgByApiKey,
  listAccessCodes,
  createAccessCode,
  deleteAccessCode,
  regenerateAccessCode,
} from './auth';
import { verifyClerkToken } from './clerk';
import { createPresignedGetUrl, createPresignedPutUrl } from './presign';

// ---------------------------------------------------------------------------
// CORS — restrict to known origins only
// ---------------------------------------------------------------------------

const ALLOWED_ORIGINS = new Set([
  'https://loader.jlwav.com',
  'http://localhost:8787',       // local dev
]);

function corsHeaders(request: Request): Record<string, string> {
  const origin = request.headers.get('Origin') || '';
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.has(origin) ? origin : '',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-API-Key, Authorization',
    'Access-Control-Max-Age': '86400',
  };
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function errorResponse(message: string, status: number): Response {
  return json({ error: message }, status);
}

/** Add CORS headers to any response. */
function withCors(response: Response, request: Request): Response {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(corsHeaders(request))) {
    headers.set(k, v);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

// ---------------------------------------------------------------------------
// Main fetch handler
// ---------------------------------------------------------------------------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    const { pathname } = new URL(request.url);

    let response: Response;
    try {
      switch (pathname) {
        case '/api/auth':
          if (request.method === 'POST') { response = await handleAuth(request, env); break; }
          response = errorResponse('Not found', 404); break;
        case '/api/manifest':
          if (request.method === 'GET') { response = await handleGetManifest(request, env); break; }
          if (request.method === 'PATCH') { response = await handlePatchManifest(request, env); break; }
          response = errorResponse('Not found', 404); break;
        case '/api/download':
          if (request.method === 'POST') { response = await handleDownload(request, env); break; }
          response = errorResponse('Not found', 404); break;
        case '/api/upload-url':
          if (request.method === 'POST') { response = await handleUploadUrl(request, env); break; }
          response = errorResponse('Not found', 404); break;
        case '/api/revert':
          if (request.method === 'POST') { response = await handleRevert(request, env); break; }
          response = errorResponse('Not found', 404); break;
        case '/api/access-codes':
          if (request.method === 'GET') { response = await handleListAccessCodes(request, env); break; }
          if (request.method === 'POST') { response = await handleCreateAccessCode(request, env); break; }
          if (request.method === 'DELETE') { response = await handleDeleteAccessCode(request, env); break; }
          response = errorResponse('Not found', 404); break;
        case '/api/access-codes/regenerate':
          if (request.method === 'POST') { response = await handleRegenerateAccessCode(request, env); break; }
          response = errorResponse('Not found', 404); break;
        default:
          response = errorResponse('Not found', 404);
      }
    } catch (err) {
      console.error('Unhandled error:', err);
      response = errorResponse('Internal server error', 500);
    }

    return withCors(response, request);
  },
};

// ---------------------------------------------------------------------------
// POST /api/auth — pilot exchanges access code for API key
// ---------------------------------------------------------------------------

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

  return json({ apiKey: entry.apiKey, orgId: entry.orgId, orgName: entry.orgName || entry.orgId });
}

// ---------------------------------------------------------------------------
// GET /api/manifest — current update manifest (pilot or admin auth)
//
// Pilot sends: X-API-Key header
// Admin sends: Authorization: Bearer <clerk_jwt>
// ---------------------------------------------------------------------------

async function handleGetManifest(request: Request, env: Env): Promise<Response> {
  const orgId = await resolveOrgId(request, env);
  if (!orgId) {
    return errorResponse('Unauthorized', 401);
  }

  const object = await env.UPDATES_BUCKET.get(`orgs/${orgId}/manifest.json`);
  if (!object) {
    // No manifest yet — org exists but no package has been uploaded
    return json({
      orgId,
      version: null,
      message: 'No update package uploaded yet',
    });
  }

  const manifest = await object.json();
  return json(manifest);
}

// ---------------------------------------------------------------------------
// POST /api/download — presigned R2 download URL (pilot auth only)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// POST /api/upload-url — presigned R2 upload URL (admin auth only)
//
// Body: { "filename": "update-2026-03.zip" }
// The web uploader PUTs the ZIP directly to R2 using this URL.
// ---------------------------------------------------------------------------

async function handleUploadUrl(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  let body: { filename?: string };
  try {
    body = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  if (!body.filename) {
    return errorResponse('filename is required', 400);
  }

  // Prevent path traversal
  if (
    body.filename.includes('/') ||
    body.filename.includes('\\') ||
    body.filename.includes('..')
  ) {
    return errorResponse('Invalid filename', 400);
  }

  const key = `orgs/${admin.orgId}/${body.filename}`;
  const uploadUrl = await createPresignedPutUrl(env, key, 900);

  return json({
    uploadUrl,
    key,
    expiresIn: 900,
  });
}

// ---------------------------------------------------------------------------
// PATCH /api/manifest — update manifest after upload (admin auth only)
//
// Body: full manifest JSON object (see ManifestData in types.ts)
// The Worker forces orgId to match the admin's org, preventing tampering.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// GET /api/access-codes — list access codes for admin's org
// ---------------------------------------------------------------------------

async function handleListAccessCodes(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  const codeNames = await listAccessCodes(env.ACCESS_CODES_KV, admin.orgId);
  const codes = codeNames.map((code) => ({ accessCode: code }));

  return json({ codes });
}

// ---------------------------------------------------------------------------
// POST /api/access-codes — create a new access code for admin's org
//
// Body: { "accessCode": "JLW-1234" }
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
    await createAccessCode(env.ACCESS_CODES_KV, admin.orgId, accessCode, admin.orgName);
    return json({ accessCode }, 201);
  } catch (err) {
    if (err instanceof Error && err.message === 'ACCESS_CODE_EXISTS') {
      return errorResponse('This access code is unavailable. Please choose a different one.', 409);
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// DELETE /api/access-codes — delete an access code from admin's org
//
// Body: { "accessCode": "JLW-1234" }
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

  if (!body.accessCode) {
    return errorResponse('accessCode is required', 400);
  }

  try {
    await deleteAccessCode(env.ACCESS_CODES_KV, admin.orgId, body.accessCode);
    return json({ success: true });
  } catch (err) {
    if (err instanceof Error && err.message === 'ACCESS_CODE_NOT_FOUND') {
      return errorResponse('Access code not found', 404);
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// POST /api/access-codes/regenerate — regenerate access code for admin's org
// ---------------------------------------------------------------------------

async function handleRegenerateAccessCode(request: Request, env: Env): Promise<Response> {
  const admin = await authenticateAdmin(request, env);
  if (!admin) {
    return errorResponse('Unauthorized', 401);
  }

  // Clerk v5 abbreviated JWT claims don't include org name — read from body
  let body: { orgName?: string } = {};
  try { body = await request.json(); } catch { /* no body is fine */ }
  const orgName = body.orgName || admin.orgName;

  try {
    const result = await regenerateAccessCode(env.ACCESS_CODES_KV, admin.orgId, orgName);
    return json({ accessCode: result.accessCode });
  } catch (err) {
    if (err instanceof Error && err.message === 'GENERATION_FAILED') {
      return errorResponse('Failed to generate unique access code. Please try again.', 500);
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

/**
 * Resolve orgId from either auth method:
 *   1. X-API-Key header (pilot) — looked up in ACCESS_CODES_KV
 *   2. Authorization: Bearer header (admin) — Clerk JWT verified
 */
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

/** Validate admin credentials from Authorization: Bearer header (Clerk JWT). */
async function authenticateAdmin(
  request: Request,
  env: Env,
): Promise<{ orgId: string; userId: string; orgName: string } | null> {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return null;

  const token = authHeader.slice(7);
  const claims = await verifyClerkToken(token, env);
  if (!claims) return null;

  return { orgId: claims.org_slug, userId: claims.sub, orgName: claims.org_name || claims.org_slug };
}
