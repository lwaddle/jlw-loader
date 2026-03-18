#!/usr/bin/env node

/**
 * Interactive helper to build the ACCESS_CODES JSON secret.
 *
 * Usage:
 *   node scripts/setup-secrets.js
 *
 * This walks you through creating the JSON blob, then prints the
 * `wrangler secret put` commands you need to run.
 */

const { randomBytes } = require('crypto');
const readline = require('readline');

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q) => new Promise((resolve) => rl.question(q, resolve));

function generateApiKey() {
  return 'key_' + randomBytes(32).toString('hex');
}

async function main() {
  console.log('\n=== JLW Loader Worker — Secret Setup ===\n');

  const accessCodes = {};

  let addMore = true;
  while (addMore) {
    console.log('--- Add an organization ---');
    const orgId = await ask('  Org ID (e.g. "jlw-aviation"): ');
    const accessCode = await ask('  Access code for pilots (e.g. "JLW-7294"): ');
    const apiKey = generateApiKey();

    accessCodes[accessCode] = { orgId, apiKey };
    console.log(`  Generated API key: ${apiKey}`);

    const more = await ask('\nAdd another organization? (y/n): ');
    addMore = more.toLowerCase() === 'y';
    console.log();
  }

  console.log('\n=== Generated Secrets ===\n');

  const accessCodesJson = JSON.stringify(accessCodes, null, 2);

  console.log('ACCESS_CODES:');
  console.log(accessCodesJson);

  console.log('\n=== Commands to set secrets ===\n');
  console.log('Run these from the worker/ directory:\n');
  console.log(`  echo '${JSON.stringify(accessCodes)}' | wrangler secret put ACCESS_CODES`);
  console.log('  wrangler secret put R2_ACCESS_KEY_ID');
  console.log('  wrangler secret put R2_SECRET_ACCESS_KEY');
  console.log('  wrangler secret put CF_ACCOUNT_ID');
  console.log('\nFor R2 API credentials, create an R2 API token in the Cloudflare dashboard:');
  console.log('  Dashboard → R2 → Manage R2 API Tokens → Create API Token');
  console.log('  Permissions: Object Read & Write on the "jlw-loader-updates" bucket\n');
  console.log('Admin auth is handled by Clerk — no admin credentials secret needed.\n');

  rl.close();
}

main().catch(console.error);
