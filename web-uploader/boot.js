/**
 * Boot script — dynamically loads Clerk SDK with the publishable key from config.
 * Extracted from inline <script> to comply with Content Security Policy.
 */
const clerkScript = document.createElement('script');
clerkScript.src = 'https://cdn.jsdelivr.net/npm/@clerk/clerk-js@5/dist/clerk.browser.js';
clerkScript.setAttribute('data-clerk-publishable-key', CONFIG.clerkPublishableKey);
clerkScript.async = true;
clerkScript.onload = function() { initClerk(); };
document.body.appendChild(clerkScript);
