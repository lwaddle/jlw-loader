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
    const p = payload as Record<string, unknown>;

    // Clerk v5 uses abbreviated claims: "o" contains { id, slg, rol, per }
    // Older tokens may use "org_slug" directly.
    let orgSlug: string | undefined;
    if (p.org_slug) {
      orgSlug = p.org_slug as string;
    } else if (p.o && typeof p.o === 'object') {
      orgSlug = (p.o as Record<string, unknown>).slg as string | undefined;
    }

    if (!sub || !orgSlug) {
      console.error('Clerk JWT missing required claims', { sub, orgSlug, o: p.o, keys: Object.keys(payload) });
      return null;
    }

    return { sub, org_slug: orgSlug };
  } catch (err) {
    console.error('Clerk JWT verification failed:', err);
    return null;
  }
}
