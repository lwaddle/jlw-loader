import { AwsClient } from 'aws4fetch';
import { Env } from './types';

/**
 * Generate a presigned GET URL for downloading an object from R2.
 *
 * The URL is valid for `expiresIn` seconds (default 15 minutes).
 * The iOS app or browser uses this URL to download directly from R2,
 * bypassing the Worker for the actual data transfer.
 */
export async function createPresignedGetUrl(
  env: Env,
  key: string,
  expiresIn = 900,
): Promise<string> {
  const client = getR2Client(env);
  const url = buildR2Url(env, key);
  url.searchParams.set('X-Amz-Expires', expiresIn.toString());

  const signed = await client.sign(new Request(url, { method: 'GET' }), {
    aws: { signQuery: true },
  });
  return signed.url;
}

/**
 * Generate a presigned PUT URL for uploading an object to R2.
 *
 * The web uploader uses this URL to upload the ZIP file directly to R2,
 * bypassing the Worker entirely for the large file transfer.
 */
export async function createPresignedPutUrl(
  env: Env,
  key: string,
  expiresIn = 900,
): Promise<string> {
  const client = getR2Client(env);
  const url = buildR2Url(env, key);
  url.searchParams.set('X-Amz-Expires', expiresIn.toString());

  const signed = await client.sign(new Request(url, { method: 'PUT' }), {
    aws: { signQuery: true },
  });
  return signed.url;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function getR2Client(env: Env): AwsClient {
  return new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
  });
}

/** Build the R2 S3-compatible endpoint URL for a given object key. */
function buildR2Url(env: Env, key: string): URL {
  return new URL(
    `https://${env.CF_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET_NAME}/${key}`,
  );
}
