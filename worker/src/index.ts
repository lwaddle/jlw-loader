/**
 * JLW Loader — Cloudflare Worker
 *
 * API gatekeeper for the JLW Loader system. Handles:
 *   - Pilot auth: access code → API key exchange
 *   - Manifest: serve current update manifest per org
 *   - Download: presigned R2 URLs for the iOS app
 *   - Upload: presigned R2 URLs for the web uploader
 *   - Manifest update: admin writes new manifest after upload
 *
 * All endpoints are scoped to an organization via auth credentials.
 * See README.md for setup and deployment instructions.
 */

import { Env } from './types';
import {
  parseAccessCodes,
  parseAdminCreds,
  findByAccessCode,
  findOrgByApiKey,
  validateAdmin,
} from './auth';
import { createPresignedGetUrl, createPresignedPutUrl } from './presign';

// ---------------------------------------------------------------------------
// CORS — the web uploader runs on a different origin (Cloudflare Pages)
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-API-Key, Authorization',
  'Access-Control-Max-Age': '86400',
};

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

function errorResponse(message: string, status: number): Response {
  return json({ error: message }, status);
}

// ---------------------------------------------------------------------------
// Main fetch handler
// ---------------------------------------------------------------------------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const { pathname } = new URL(request.url);

    try {
      switch (pathname) {
        case '/api/auth':
          if (request.method === 'POST') return handleAuth(request, env);
          break;
        case '/api/manifest':
          if (request.method === 'GET') return handleGetManifest(request, env);
          if (request.method === 'PATCH') return handlePatchManifest(request, env);
          break;
        case '/api/download':
          if (request.method === 'POST') return handleDownload(request, env);
          break;
        case '/api/upload-url':
          if (request.method === 'POST') return handleUploadUrl(request, env);
          break;
      }

      return errorResponse('Not found', 404);
    } catch (err) {
      console.error('Unhandled error:', err);
      return errorResponse('Internal server error', 500);
    }
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

  const codes = parseAccessCodes(env.ACCESS_CODES);
  const entry = findByAccessCode(codes, body.accessCode.trim());

  if (!entry) {
    return errorResponse(
      'Access code not recognized. Contact your administrator.',
      401,
    );
  }

  return json({ apiKey: entry.apiKey, orgId: entry.orgId });
}

// ---------------------------------------------------------------------------
// GET /api/manifest — current update manifest (pilot or admin auth)
//
// Pilot sends: X-API-Key header
// Admin sends: Authorization: Basic header
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

  const codes = parseAccessCodes(env.ACCESS_CODES);
  const orgId = findOrgByApiKey(codes, apiKey);
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

  let manifest: Record<string, unknown>;
  try {
    manifest = await request.json();
  } catch {
    return errorResponse('Invalid JSON body', 400);
  }

  // Force orgId to the admin's org — never trust client-supplied orgId
  manifest.orgId = admin.orgId;

  await env.UPDATES_BUCKET.put(
    `orgs/${admin.orgId}/manifest.json`,
    JSON.stringify(manifest, null, 2),
    { httpMetadata: { contentType: 'application/json' } },
  );

  return json({ success: true, orgId: admin.orgId });
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

/**
 * Resolve orgId from either auth method:
 *   1. X-API-Key header (pilot) — looked up in ACCESS_CODES
 *   2. Authorization: Basic header (admin) — validated against ADMIN_CREDS
 */
async function resolveOrgId(request: Request, env: Env): Promise<string | null> {
  // Pilot auth
  const apiKey = request.headers.get('X-API-Key');
  if (apiKey) {
    const codes = parseAccessCodes(env.ACCESS_CODES);
    return findOrgByApiKey(codes, apiKey);
  }

  // Admin auth
  const admin = await authenticateAdmin(request, env);
  return admin?.orgId ?? null;
}

/** Validate admin credentials from Authorization: Basic header. */
async function authenticateAdmin(
  request: Request,
  env: Env,
): Promise<{ orgId: string; username: string } | null> {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader) return null;

  const creds = parseAdminCreds(env.ADMIN_CREDS);
  return validateAdmin(creds, authHeader);
}
