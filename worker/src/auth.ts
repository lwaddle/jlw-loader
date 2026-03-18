import { AccessCodeEntry } from './types';

// ---------------------------------------------------------------------------
// Access code lookups (pilot auth) — backed by KV
// ---------------------------------------------------------------------------

export async function findByAccessCode(
  kv: KVNamespace,
  code: string,
): Promise<AccessCodeEntry | null> {
  const entry = await kv.get<AccessCodeEntry>(`code:${code}`, 'json');
  return entry ?? null;
}

export async function findOrgByApiKey(
  kv: KVNamespace,
  apiKey: string,
): Promise<string | null> {
  const list = await kv.list({ prefix: 'code:' });
  for (const key of list.keys) {
    const entry = await kv.get<AccessCodeEntry>(key.name, 'json');
    if (entry && constantTimeEqual(entry.apiKey, apiKey)) {
      return entry.orgId;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Access code management (admin CRUD)
// ---------------------------------------------------------------------------

export function generateApiKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return 'key_' + hex;
}

export async function listAccessCodes(
  kv: KVNamespace,
  orgId: string,
): Promise<string[]> {
  const codes = await kv.get<string[]>(`org:${orgId}:codes`, 'json');
  return codes ?? [];
}

async function saveOrgIndex(
  kv: KVNamespace,
  orgId: string,
  codes: string[],
): Promise<void> {
  await kv.put(`org:${orgId}:codes`, JSON.stringify(codes));
}

export async function createAccessCode(
  kv: KVNamespace,
  orgId: string,
  accessCode: string,
): Promise<string> {
  const existing = await kv.get(`code:${accessCode}`);
  if (existing !== null) {
    throw new Error('ACCESS_CODE_EXISTS');
  }

  const apiKey = generateApiKey();
  const entry: AccessCodeEntry = { orgId, apiKey };

  await kv.put(`code:${accessCode}`, JSON.stringify(entry));

  const codes = await listAccessCodes(kv, orgId);
  codes.push(accessCode);
  await saveOrgIndex(kv, orgId, codes);

  return apiKey;
}

export async function deleteAccessCode(
  kv: KVNamespace,
  orgId: string,
  accessCode: string,
): Promise<void> {
  const existing = await kv.get(`code:${accessCode}`);
  if (existing === null) {
    throw new Error('ACCESS_CODE_NOT_FOUND');
  }

  await kv.delete(`code:${accessCode}`);

  const codes = await listAccessCodes(kv, orgId);
  const updated = codes.filter((c) => c !== accessCode);
  await saveOrgIndex(kv, orgId, updated);
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
