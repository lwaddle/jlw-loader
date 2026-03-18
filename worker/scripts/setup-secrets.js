#!/usr/bin/env node

/**
 * Interactive helper to build the ACCESS_CODES and ADMIN_CREDS JSON secrets.
 *
 * Usage:
 *   node scripts/setup-secrets.js
 *
 * This walks you through creating the JSON blobs, then prints the
 * `wrangler secret put` commands you need to run.
 */

const { pbkdf2Sync, randomBytes } = require('crypto');
const readline = require('readline');

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q) => new Promise((resolve) => rl.question(q, resolve));

function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const hash = pbkdf2Sync(password, salt, 600_000, 32, 'sha256').toString('hex');
  return `${salt}:${hash}`;
}

function generateApiKey() {
  return 'key_' + randomBytes(32).toString('hex');
}

async function main() {
  console.log('\n=== JLW Loader Worker — Secret Setup ===\n');

  const accessCodes = {};
  const adminCreds = {};

  let addMore = true;
  while (addMore) {
    console.log('--- Add an organization ---');
    const orgId = await ask('  Org ID (e.g. "jlw-aviation"): ');
    const accessCode = await ask('  Access code for pilots (e.g. "JLW-7294"): ');
    const apiKey = generateApiKey();

    accessCodes[accessCode] = { orgId, apiKey };
    console.log(`  Generated API key: ${apiKey}`);

    const adminUser = await ask('  Admin username (e.g. "loren"): ');
    const adminPass = await ask('  Admin password: ');
    const passwordHash = hashPassword(adminPass);

    adminCreds[adminUser.toLowerCase()] = { passwordHash, orgId };

    const more = await ask('\nAdd another organization? (y/n): ');
    addMore = more.toLowerCase() === 'y';
    console.log();
  }

  console.log('\n=== Generated Secrets ===\n');

  const accessCodesJson = JSON.stringify(accessCodes, null, 2);
  const adminCredsJson = JSON.stringify(adminCreds, null, 2);

  console.log('ACCESS_CODES:');
  console.log(accessCodesJson);
  console.log('\nADMIN_CREDS:');
  console.log(adminCredsJson);

  console.log('\n=== Commands to set secrets ===\n');
  console.log('Run these from the worker/ directory:\n');
  console.log(`  echo '${JSON.stringify(accessCodes)}' | wrangler secret put ACCESS_CODES`);
  console.log(`  echo '${JSON.stringify(adminCreds)}' | wrangler secret put ADMIN_CREDS`);
  console.log('  wrangler secret put R2_ACCESS_KEY_ID');
  console.log('  wrangler secret put R2_SECRET_ACCESS_KEY');
  console.log('  wrangler secret put CF_ACCOUNT_ID');
  console.log('\nFor R2 API credentials, create an R2 API token in the Cloudflare dashboard:');
  console.log('  Dashboard → R2 → Manage R2 API Tokens → Create API Token');
  console.log('  Permissions: Object Read & Write on the "jlw-loader-updates" bucket\n');

  rl.close();
}

main().catch(console.error);
