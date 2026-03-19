import { createRemoteJWKSet, jwtVerify } from 'jose';
import { Env } from './types';

/** Cached JWKS fetcher — reused across requests within the same Worker isolate. */
let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

export interface ClerkClaims {
  sub: string;
  org_slug: string;
  org_name: string;
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

    // Clerk v5 uses abbreviated claims: "o" contains { id, slg, rol, per, nam }
    // Older tokens may use "org_slug" / "org_name" directly.
    let orgSlug: string | undefined;
    let orgName: string | undefined;
    if (p.org_slug) {
      orgSlug = p.org_slug as string;
      orgName = p.org_name as string | undefined;
    } else if (p.o && typeof p.o === 'object') {
      const o = p.o as Record<string, unknown>;
      orgSlug = o.slg as string | undefined;
      orgName = o.nam as string | undefined;
    }

    if (!sub || !orgSlug) {
      console.error('Clerk JWT missing required claims', { sub, orgSlug, o: p.o, keys: Object.keys(payload) });
      return null;
    }

    return { sub, org_slug: orgSlug, org_name: orgName || orgSlug };
  } catch (err) {
    console.error('Clerk JWT verification failed:', err);
    return null;
  }
}
