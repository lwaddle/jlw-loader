import { AccessCodeEntry } from './types';

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
// Crypto helpers
// ---------------------------------------------------------------------------

/** Constant-time string comparison to prevent timing attacks. */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
