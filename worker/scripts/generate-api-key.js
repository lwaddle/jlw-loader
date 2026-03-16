#!/usr/bin/env node

/**
 * Generate a random API key for ACCESS_CODES.
 *
 * Usage:
 *   node scripts/generate-api-key.js
 *   npm run generate-api-key
 *
 * Output:
 *   key_<32 random hex chars>
 *
 * Copy the output into the ACCESS_CODES JSON secret.
 */

const { randomBytes } = require('crypto');

const key = 'key_' + randomBytes(32).toString('hex');

console.log(`\nAPI key (copy this into ACCESS_CODES):\n`);
console.log(`  ${key}`);
console.log();
