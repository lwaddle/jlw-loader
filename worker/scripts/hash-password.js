#!/usr/bin/env node

/**
 * Generate a salted SHA-256 password hash for ADMIN_CREDS.
 *
 * Usage:
 *   node scripts/hash-password.js <password>
 *   npm run hash-password -- <password>
 *
 * Output:
 *   <salt>:<sha256hex>
 *
 * Copy the output into the ADMIN_CREDS JSON secret.
 */

const { createHash, randomBytes } = require('crypto');

const password = process.argv[2];
if (!password) {
  console.error('Usage: node scripts/hash-password.js <password>');
  process.exit(1);
}

const salt = randomBytes(16).toString('hex');
const hash = createHash('sha256').update(salt + password).digest('hex');

console.log(`\nPassword hash (copy this into ADMIN_CREDS):\n`);
console.log(`  ${salt}:${hash}`);
console.log();
