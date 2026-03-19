#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const SRC = __dirname;
const DIST = path.join(SRC, "dist");

function hash(filePath) {
  const content = fs.readFileSync(filePath);
  return crypto.createHash("md5").update(content).digest("hex").slice(0, 8);
}

// Clean and create dist/
if (fs.existsSync(DIST)) fs.rmSync(DIST, { recursive: true });
fs.mkdirSync(DIST);

// Hash app.js and style.css
const appHash = hash(path.join(SRC, "app.js"));
const cssHash = hash(path.join(SRC, "style.css"));

const appOut = `app.${appHash}.js`;
const cssOut = `style.${cssHash}.css`;

fs.copyFileSync(path.join(SRC, "app.js"), path.join(DIST, appOut));
fs.copyFileSync(path.join(SRC, "style.css"), path.join(DIST, cssOut));

// Rewrite index.html references
let html = fs.readFileSync(path.join(SRC, "index.html"), "utf8");
html = html.replace('href="style.css"', `href="${cssOut}"`);
html = html.replace('src="app.js"', `src="${appOut}"`);
fs.writeFileSync(path.join(DIST, "index.html"), html);

// Copy config.js and _headers as-is
fs.copyFileSync(path.join(SRC, "config.js"), path.join(DIST, "config.js"));
fs.copyFileSync(path.join(SRC, "_headers"), path.join(DIST, "_headers"));

console.log(`Build complete:`);
console.log(`  ${appOut}`);
console.log(`  ${cssOut}`);
