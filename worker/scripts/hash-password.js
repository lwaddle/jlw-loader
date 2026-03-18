#!/usr/bin/env node

/**
 * Generate a salted PBKDF2-SHA-256 password hash for ADMIN_CREDS.
 *
 * Usage:
 *   node scripts/hash-password.js <password>
 *   npm run hash-password -- <password>
 *
 * Output:
 *   <salt>:<pbkdf2hex>
 *
 * Copy the output into the ADMIN_CREDS JSON secret.
 */

const { pbkdf2Sync, randomBytes } = require('crypto');

const password = process.argv[2];
if (!password) {
  console.error('Usage: node scripts/hash-password.js <password>');
  process.exit(1);
}

const salt = randomBytes(16).toString('hex');
const hash = pbkdf2Sync(password, salt, 600_000, 32, 'sha256').toString('hex');

console.log(`\nPassword hash (copy this into ADMIN_CREDS):\n`);
console.log(`  ${salt}:${hash}`);
console.log();
