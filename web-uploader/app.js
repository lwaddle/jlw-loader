/**
 * JLW Loader — Web Uploader
 *
 * Single-page admin interface for uploading avionics update packages.
 * Communicates with the Cloudflare Worker API using Basic auth.
 * No dependencies — vanilla JS only.
 */

// ── CONFIGURATION ─────────────────────────────────────────────────
// Worker URL is set in config.js (loaded before this file).
// Edit config.js to point to your Worker — it's the only file
// that changes between local dev and production.
const API_BASE = CONFIG.workerUrl.replace(/\/+$/, ''); // strip trailing slash

// ── STATE ─────────────────────────────────────────────────────────
let credentials = null;   // { username, password } — held in memory only
let currentManifest = null;
let selectedFile = null;

// ── DOM REFS ──────────────────────────────────────────────────────
const loginView     = document.getElementById('login-view');
const dashboardView = document.getElementById('dashboard-view');
const loginForm     = document.getElementById('login-form');
const loginBtn      = document.getElementById('login-btn');
const loginError    = document.getElementById('login-error');
const orgName       = document.getElementById('org-name');
const logoutBtn     = document.getElementById('logout-btn');
const pkgStatus     = document.getElementById('pkg-status');
const pkgDetails    = document.getElementById('pkg-details');
const pkgEmpty      = document.getElementById('pkg-empty');
const uploadForm    = document.getElementById('upload-form');
const uploadBtn     = document.getElementById('upload-btn');
const dropZone      = document.getElementById('drop-zone');
const fileInput     = document.getElementById('file-input');
const fileInfo      = document.getElementById('file-info');
const fileName      = document.getElementById('file-name');
const fileSize      = document.getElementById('file-size');
const fileRemove    = document.getElementById('file-remove');
const progressWrap  = document.getElementById('upload-progress');
const progressLabel = document.getElementById('progress-label');
const progressPct   = document.getElementById('progress-pct');
const progressBar   = document.getElementById('progress-bar');
const uploadResult  = document.getElementById('upload-result');

// ── AUTH HELPERS ───────────────────────────────────────────────────

function basicAuthHeader() {
  var bytes = new TextEncoder().encode(credentials.username + ':' + credentials.password);
  var binary = '';
  for (var i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return 'Basic ' + btoa(binary);
}

async function apiCall(method, path, body) {
  const headers = {
    'Authorization': basicAuthHeader(),
  };
  if (body) {
    headers['Content-Type'] = 'application/json';
  }
  const resp = await fetch(API_BASE + path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await resp.json();
  if (!resp.ok) {
    throw new Error(data.error || 'Request failed (' + resp.status + ')');
  }
  return data;
}

// ── LOGIN ─────────────────────────────────────────────────────────

loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  loginError.hidden = true;

  const username = document.getElementById('username').value.trim();
  const password = document.getElementById('password').value;

  if (!username || !password) return;

  setLoading(loginBtn, true);

  try {
    credentials = { username, password };
    const manifest = await apiCall('GET', '/api/manifest');
    currentManifest = manifest;
    showDashboard();
  } catch (err) {
    credentials = null;
    loginError.textContent = err.message;
    loginError.hidden = false;
  } finally {
    setLoading(loginBtn, false);
  }
});

logoutBtn.addEventListener('click', () => {
  credentials = null;
  currentManifest = null;
  selectedFile = null;
  loginForm.reset();
  loginError.hidden = true;
  uploadForm.reset();
  resetUploadUI();
  dashboardView.hidden = true;
  loginView.hidden = false;
});

// ── DASHBOARD ─────────────────────────────────────────────────────

function showDashboard() {
  loginView.hidden = true;
  dashboardView.hidden = false;
  renderManifest();
}

function renderManifest() {
  const m = currentManifest;
  orgName.textContent = m.orgId || 'Unknown';

  // Clear previous content
  while (pkgDetails.firstChild) {
    pkgDetails.removeChild(pkgDetails.firstChild);
  }

  if (!m.uploadedAt) {
    pkgDetails.hidden = true;
    pkgEmpty.hidden = false;
    pkgStatus.textContent = 'No Package';
    pkgStatus.className = 'status-badge empty';
    return;
  }

  pkgDetails.hidden = false;
  pkgEmpty.hidden = true;
  pkgStatus.textContent = 'Active';
  pkgStatus.className = 'status-badge active';

  const sizeDisplay = m.packageSizeBytes ? formatBytes(m.packageSizeBytes) : '—';
  const uploadedDisplay = m.uploadedAt ? formatRelativeDate(m.uploadedAt) : '—';

  // Build fields using safe DOM methods
  const fields = [
    { label: 'Filename',     value: m.packageFilename || '—', mono: true },
    { label: 'Package Size', value: sizeDisplay },
    { label: 'Uploaded',     value: uploadedDisplay },
  ];
  if (m.packageChecksum) {
    fields.push({ label: 'Checksum', value: m.packageChecksum, mono: true, fullWidth: true });
  }

  fields.forEach((f) => {
    const div = document.createElement('div');
    div.className = 'pkg-field' + (f.fullWidth ? ' full-width' : '');

    const labelSpan = document.createElement('span');
    labelSpan.className = 'pkg-label';
    labelSpan.textContent = f.label;

    const valueSpan = document.createElement('span');
    valueSpan.className = 'pkg-value' + (f.mono ? ' mono' : '');
    valueSpan.textContent = f.value;

    div.appendChild(labelSpan);
    div.appendChild(valueSpan);
    pkgDetails.appendChild(div);
  });
}

// ── FILE SELECTION ────────────────────────────────────────────────

dropZone.addEventListener('click', () => fileInput.click());

dropZone.addEventListener('dragover', (e) => {
  e.preventDefault();
  dropZone.classList.add('drag-over');
});

dropZone.addEventListener('dragleave', () => {
  dropZone.classList.remove('drag-over');
});

dropZone.addEventListener('drop', (e) => {
  e.preventDefault();
  dropZone.classList.remove('drag-over');
  const file = e.dataTransfer.files[0];
  if (file) selectFile(file);
});

fileInput.addEventListener('change', () => {
  if (fileInput.files[0]) selectFile(fileInput.files[0]);
});

fileRemove.addEventListener('click', () => {
  selectedFile = null;
  fileInput.value = '';
  fileInfo.hidden = true;
  dropZone.hidden = false;
  validateUploadForm();
});

function selectFile(file) {
  if (!file.name.toLowerCase().endsWith('.zip')) {
    showResult('error', 'Please select a .zip file.');
    return;
  }
  selectedFile = file;
  fileName.textContent = file.name;
  fileSize.textContent = formatBytes(file.size);
  fileInfo.hidden = false;
  dropZone.hidden = true;
  uploadResult.hidden = true;
  validateUploadForm();
}

// ── FORM VALIDATION ───────────────────────────────────────────────

function validateUploadForm() {
  uploadBtn.disabled = !selectedFile;
}

// ── UPLOAD FLOW ───────────────────────────────────────────────────
//
// 1. Compute SHA-256 checksum of the ZIP (client-side)
// 2. Request presigned PUT URL from Worker
// 3. Upload ZIP directly to R2
// 4. Update manifest via Worker
//

uploadForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!selectedFile) return;

  setLoading(uploadBtn, true);
  uploadBtn.disabled = true;
  uploadResult.hidden = true;
  progressWrap.hidden = false;

  try {
    // Step 1: Hash the file
    setProgress('hashing', 'Computing checksum...', 0);
    const checksum = await hashFile(selectedFile);
    setProgress('hashing', 'Checksum computed', 100);

    // Step 2: Get presigned upload URL
    setProgress('uploading', 'Requesting upload URL...', 0);
    const urlResp = await apiCall('POST', '/api/upload-url', { filename: selectedFile.name });

    // Step 3: Upload ZIP to R2
    setProgress('uploading', 'Uploading to R2...', 0);
    await uploadToR2(urlResp.uploadUrl, selectedFile);
    setProgress('uploading', 'Upload complete', 100);

    // Step 4: Update manifest
    setProgress('uploading', 'Updating manifest...', 100);
    await apiCall('PATCH', '/api/manifest', {
      packageFilename: selectedFile.name,
      packageSizeBytes: selectedFile.size,
      packageChecksum: 'sha256:' + checksum,
      uploadedAt: new Date().toISOString(),
    });

    // Done — refresh manifest and show success
    currentManifest = await apiCall('GET', '/api/manifest');
    renderManifest();
    showResult('success', 'Package uploaded successfully.');
    resetUploadUI();

  } catch (err) {
    showResult('error', err.message);
  } finally {
    setLoading(uploadBtn, false);
    validateUploadForm();
  }
});

/**
 * Upload file to R2 via presigned PUT URL with progress tracking.
 */
function uploadToR2(url, file) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', url);
    xhr.setRequestHeader('Content-Type', 'application/zip');

    xhr.upload.addEventListener('progress', (e) => {
      if (e.lengthComputable) {
        const pct = Math.round((e.loaded / e.total) * 100);
        setProgress('uploading', 'Uploading... ' + formatBytes(e.loaded) + ' / ' + formatBytes(e.total), pct);
      }
    });

    xhr.addEventListener('load', () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve();
      } else {
        reject(new Error('R2 upload failed (HTTP ' + xhr.status + ')'));
      }
    });

    xhr.addEventListener('error', () => reject(new Error('Upload failed — network error')));
    xhr.addEventListener('abort', () => reject(new Error('Upload cancelled')));

    xhr.send(file);
  });
}

/**
 * Compute SHA-256 hash of a File using Web Crypto API.
 * Reads in 2MB chunks for large files to show progress.
 */
async function hashFile(file) {
  // For files under 50MB, single-pass approach
  if (file.size < 50 * 1024 * 1024) {
    const buffer = await file.arrayBuffer();
    const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
    return Array.from(new Uint8Array(hashBuffer))
      .map(function (b) { return b.toString(16).padStart(2, '0'); })
      .join('');
  }

  // For larger files, read in chunks and show read progress
  var CHUNK_SIZE = 2 * 1024 * 1024;
  var totalChunks = Math.ceil(file.size / CHUNK_SIZE);
  var chunks = [];
  var offset = 0;
  var chunkIndex = 0;

  while (offset < file.size) {
    var slice = file.slice(offset, offset + CHUNK_SIZE);
    var buffer = await slice.arrayBuffer();
    chunks.push(new Uint8Array(buffer));
    offset += CHUNK_SIZE;
    chunkIndex++;
    var pct = Math.round((chunkIndex / totalChunks) * 90);
    setProgress('hashing', 'Reading file... ' + formatBytes(offset) + ' / ' + formatBytes(file.size), pct);
  }

  // Concatenate and hash
  var totalLength = chunks.reduce(function (sum, c) { return sum + c.length; }, 0);
  var combined = new Uint8Array(totalLength);
  var pos = 0;
  for (var i = 0; i < chunks.length; i++) {
    combined.set(chunks[i], pos);
    pos += chunks[i].length;
  }

  setProgress('hashing', 'Hashing...', 95);
  var hashBuffer = await crypto.subtle.digest('SHA-256', combined);
  return Array.from(new Uint8Array(hashBuffer))
    .map(function (b) { return b.toString(16).padStart(2, '0'); })
    .join('');
}

// ── UI HELPERS ────────────────────────────────────────────────────

function setLoading(btn, loading) {
  var text = btn.querySelector('.btn-text');
  var spinner = btn.querySelector('.btn-spinner');
  if (text) text.hidden = loading;
  if (spinner) spinner.hidden = !loading;
}

function setProgress(type, label, pct) {
  progressWrap.hidden = false;
  progressLabel.textContent = label;
  progressPct.textContent = pct + '%';
  progressBar.style.width = pct + '%';
  progressBar.className = 'progress-fill ' + type;
}

function showResult(type, message) {
  uploadResult.hidden = false;
  uploadResult.className = 'upload-result ' + type;
  uploadResult.textContent = message;
}

function resetUploadUI() {
  selectedFile = null;
  fileInput.value = '';
  fileInfo.hidden = true;
  dropZone.hidden = false;
  progressWrap.hidden = true;
  progressBar.style.width = '0%';
  uploadForm.reset();
}

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function formatRelativeDate(iso) {
  var date = new Date(iso);
  var now = new Date();
  var diffMs = now - date;
  var diffMins = Math.floor(diffMs / 60000);
  var diffHours = Math.floor(diffMs / 3600000);
  var diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'just now';
  if (diffMins < 60) return diffMins + ' min ago';
  if (diffHours < 24) return diffHours + ' hours ago';
  if (diffDays === 1) return 'yesterday';
  if (diffDays < 30) return diffDays + ' days ago';
  return date.toLocaleDateString();
}
