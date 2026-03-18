import { AccessCodeEntry, AdminCredEntry } from './types';

// ---------------------------------------------------------------------------
// Access code lookups (pilot auth)
// ---------------------------------------------------------------------------

export function parseAccessCodes(json: string): Record<string, AccessCodeEntry> {
  return JSON.parse(json);
}

/** Look up an access code entry by the friendly code (e.g. "JLW-7294"). */
export function findByAccessCode(
  codes: Record<string, AccessCodeEntry>,
  code: string,
): AccessCodeEntry | null {
  return codes[code] ?? null;
}

/** Reverse-lookup: given an API key, find the orgId it belongs to. */
export function findOrgByApiKey(
  codes: Record<string, AccessCodeEntry>,
  apiKey: string,
): string | null {
  for (const entry of Object.values(codes)) {
    if (constantTimeEqual(entry.apiKey, apiKey)) {
      return entry.orgId;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Admin credential validation (Basic auth)
// ---------------------------------------------------------------------------

export function parseAdminCreds(json: string): Record<string, AdminCredEntry> {
  return JSON.parse(json);
}

/**
 * Validate an Authorization: Basic header against stored admin credentials.
 * Returns { orgId, username } on success, null on failure.
 */
export async function validateAdmin(
  creds: Record<string, AdminCredEntry>,
  authHeader: string,
): Promise<{ orgId: string; username: string } | null> {
  if (!authHeader.startsWith('Basic ')) return null;

  let decoded: string;
  try {
    decoded = atob(authHeader.slice(6));
  } catch {
    return null; // malformed base64
  }
  const colonIdx = decoded.indexOf(':');
  if (colonIdx === -1) return null;

  const username = decoded.slice(0, colonIdx).toLowerCase();
  const password = decoded.slice(colonIdx + 1);

  const entry = creds[username];
  if (!entry) return null;

  const separatorIdx = entry.passwordHash.indexOf(':');
  if (separatorIdx === -1) return null;

  const salt = entry.passwordHash.slice(0, separatorIdx);
  const expectedHash = entry.passwordHash.slice(separatorIdx + 1);
  const actualHash = await hashPassword(password, salt);

  if (!constantTimeEqual(actualHash, expectedHash)) return null;

  return { orgId: entry.orgId, username };
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

/** PBKDF2-SHA-256 hash of password with salt, returned as lowercase hex. */
export async function hashPassword(password: string, salt: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey(
    'raw',
    encoder.encode(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const buf = await crypto.subtle.deriveBits(
    {
      name: 'PBKDF2',
      salt: encoder.encode(salt),
      iterations: 600_000,
      hash: 'SHA-256',
    },
    keyMaterial,
    256,
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Constant-time string comparison to prevent timing attacks. */
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
