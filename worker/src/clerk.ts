import { createRemoteJWKSet, jwtVerify } from 'jose';
import { Env } from './types';

/** Cached JWKS fetcher — reused across requests within the same Worker isolate. */
let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

export interface ClerkClaims {
  sub: string;
  org_slug: string;
}

/**
 * Verify a Clerk JWT and return the subject + org slug.
 * Returns null if the token is invalid or missing required claims.
 */
export async function verifyClerkToken(
  token: string,
  env: Env,
): Promise<ClerkClaims | null> {
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(env.CLERK_JWKS_URL));
  }

  try {
    const { payload } = await jwtVerify(token, jwks, {
      issuer: env.CLERK_ISSUER,
    });

    const sub = payload.sub;
    const orgSlug =
      (payload as Record<string, unknown>).org_slug as string | undefined;

    if (!sub || !orgSlug) return null;

    return { sub, org_slug: orgSlug };
  } catch {
    return null;
  }
}
