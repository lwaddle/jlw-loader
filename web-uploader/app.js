/**
 * JLW Loader — Web Uploader
 *
 * Single-page admin interface for uploading avionics update packages.
 * Communicates with the Cloudflare Worker API using Clerk session tokens.
 * No dependencies beyond Clerk — vanilla JS only.
 */

// ── CONFIGURATION ─────────────────────────────────────────────────
// Worker URL is set in config.js (loaded before this file).
// Edit config.js to point to your Worker — it's the only file
// that changes between local dev and production.
const API_BASE = CONFIG.workerUrl.replace(/\/+$/, ''); // strip trailing slash

// ── STATE ─────────────────────────────────────────────────────────
let currentManifest = null;
let selectedFile = null;

// ── DOM REFS ──────────────────────────────────────────────────────
const loginView     = document.getElementById('login-view');
const dashboardView = document.getElementById('dashboard-view');
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
const accessCodeDisplay = document.getElementById('access-code-display');
const accessCodeValue   = document.getElementById('access-code-value');
const accessCodeLoading = document.getElementById('access-code-loading');
const accessCodeError   = document.getElementById('access-code-error');
const copyCodeBtn       = document.getElementById('copy-code-btn');
const regenerateCodeBtn = document.getElementById('regenerate-code-btn');
const orgDropdown  = document.getElementById('org-dropdown');

// ── FILENAME GENERATION ──────────────────────────────────────────

/**
 * Generate a timestamp-based filename: update-YYYY-MM-DD-HHMMSS.zip
 */
function generatePackageFilename() {
  var now = new Date();
  var pad = function (n) { return n.toString().padStart(2, '0'); };
  return 'update-' + now.getFullYear()
    + '-' + pad(now.getMonth() + 1)
    + '-' + pad(now.getDate())
    + '-' + pad(now.getHours())
    + pad(now.getMinutes())
    + pad(now.getSeconds())
    + '.zip';
}

// ── CLERK INIT ────────────────────────────────────────────────────

let clerk = null;

let clerkReady = false;
let signInMounted = false;

async function initClerk() {
  // When loaded with data-clerk-publishable-key, window.Clerk is the
  // auto-initialized instance (not a constructor). Wait for it to be ready.
  clerk = window.Clerk;
  await clerk.load();

  clerk.addListener(handleClerkState);
  handleClerkState();
}

async function handleClerkState() {
  if (!clerk.user) {
    clerkReady = false;
    showSignIn();
    return;
  }

  // User is signed in — tear down sign-in component
  signInMounted = false;

  // Ensure the user has an active organization set
  const memberships = clerk.user.organizationMemberships;
  if (memberships && memberships.length > 0 && !clerk.organization) {
    await clerk.setActive({
      organization: memberships[0].organization.id,
    });
    return;
  }

  // Avoid re-entry — setActive triggers another listener call
  if (clerkReady) return;

  clerkReady = true;
  closeOrgDropdown();
  resetUploadUI();
  await loadDashboard();
}

function showSignIn() {
  // Don't remount if sign-in is already showing — remounting mid-flow
  // destroys the in-progress sign-in and re-triggers verification emails.
  if (signInMounted) return;
  signInMounted = true;

  loginView.hidden = false;
  dashboardView.hidden = true;
  clerk.mountSignIn(document.getElementById('clerk-sign-in'));
}

async function loadDashboard() {
  clerk.unmountSignIn(document.getElementById('clerk-sign-in'));

  try {
    const manifest = await apiCall('GET', '/api/manifest');
    currentManifest = manifest;
    await loadAccessCode();
    showDashboard();
  } catch (err) {
    console.error('Failed to load manifest:', err);
    // Show error instead of signing out to avoid loops
    loginView.hidden = false;
    dashboardView.hidden = true;
    var el = document.getElementById('clerk-sign-in');
    el.textContent = 'Failed to load dashboard: ' + err.message;
  }
}

// ── AUTH HELPERS ───────────────────────────────────────────────────

async function getAuthToken() {
  return clerk.session.getToken();
}

async function apiCall(method, path, body) {
  const token = await getAuthToken();
  const headers = {
    'Authorization': 'Bearer ' + token,
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

// ── LOGOUT ────────────────────────────────────────────────────────

logoutBtn.addEventListener('click', async () => {
  currentManifest = null;
  selectedFile = null;
  signInMounted = false;
  uploadForm.reset();
  resetUploadUI();
  await clerk.signOut();
});

// ── DASHBOARD ─────────────────────────────────────────────────────

function showDashboard() {
  loginView.hidden = true;
  dashboardView.hidden = false;
  renderManifest();
}

function renderManifest() {
  const m = currentManifest;
  orgName.textContent = (clerk.organization && clerk.organization.name) || m.orgId || 'Unknown';

  // Show dropdown affordance if user has multiple orgs
  const memberships = clerk.user.organizationMemberships;
  if (memberships && memberships.length > 1) {
    orgName.classList.add('has-switcher');
    orgName.onclick = toggleOrgDropdown;
  } else {
    orgName.classList.remove('has-switcher');
    orgName.onclick = null;
  }

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

// ── ACCESS CODE ──────────────────────────────────────────────────

var currentAccessCode = null;

async function loadAccessCode() {
  accessCodeDisplay.hidden = true;
  accessCodeLoading.hidden = false;
  accessCodeError.hidden = true;

  try {
    var codesResp = await apiCall('GET', '/api/access-codes');
    var codes = codesResp.codes || [];

    if (codes.length === 1) {
      currentAccessCode = codes[0].accessCode;
      showAccessCode(currentAccessCode);
    } else {
      // No codes or multiple codes — regenerate to get a single fresh one
      await regenerateCode(true);
    }
  } catch (err) {
    accessCodeLoading.hidden = true;
    accessCodeError.textContent = 'Failed to load access code: ' + err.message;
    accessCodeError.hidden = false;
  }
}

function showAccessCode(code) {
  accessCodeValue.textContent = code;
  accessCodeDisplay.hidden = false;
  accessCodeLoading.hidden = true;
}

async function regenerateCode(silent) {
  accessCodeError.hidden = true;
  if (!silent) {
    accessCodeDisplay.hidden = true;
    accessCodeLoading.hidden = false;
  }

  try {
    var resp = await apiCall('POST', '/api/access-codes/regenerate', {
      orgName: clerk.organization && clerk.organization.name,
    });
    currentAccessCode = resp.accessCode;
    showAccessCode(currentAccessCode);
  } catch (err) {
    accessCodeLoading.hidden = true;
    accessCodeError.textContent = 'Failed to generate code: ' + err.message;
    accessCodeError.hidden = false;
  }
}

copyCodeBtn.addEventListener('click', function () {
  if (!currentAccessCode) return;
  navigator.clipboard.writeText(currentAccessCode).then(function () {
    copyCodeBtn.textContent = '\u2713';
    setTimeout(function () { copyCodeBtn.textContent = '\u2398'; }, 1500);
  });
});

regenerateCodeBtn.addEventListener('click', function () {
  if (confirm('Generate a new access code?\n\nThe current code will stop working. You will need to share the new code with your pilots.')) {
    regenerateCode(false);
  }
});

// ── FOLDER READING ───────────────────────────────────────────────

/**
 * Recursively read all files from a list of DataTransferItems.
 * Returns an array of { path: 'E-Maps/crate.xml', file: File }
 */
async function readDroppedItems(dataTransferItems) {
  const entries = [];
  for (const item of dataTransferItems) {
    const entry = item.webkitGetAsEntry();
    if (entry) entries.push(entry);
  }

  const files = [];
  await Promise.all(entries.map(e => readEntry(e, '', files)));
  return files;
}

/**
 * Recursively read a FileSystemEntry into the files array.
 */
async function readEntry(entry, prefix, files) {
  if (entry.isFile) {
    const file = await new Promise(resolve => entry.file(resolve));
    const path = prefix + entry.name;
    // Skip macOS resource forks
    if (!path.startsWith('__MACOSX/') && !entry.name.startsWith('._')) {
      files.push({ path, file });
    }
  } else if (entry.isDirectory) {
    const dirReader = entry.createReader();
    const dirEntries = await readDirectoryFully(dirReader);
    await Promise.all(dirEntries.map(e => readEntry(e, prefix + entry.name + '/', files)));
  }
}

/**
 * DirectoryReader.readEntries() returns up to 100 entries at a time.
 * Call repeatedly until it returns an empty array.
 */
function readDirectoryFully(dirReader) {
  return new Promise((resolve, reject) => {
    const allEntries = [];
    function readBatch() {
      dirReader.readEntries(entries => {
        if (entries.length === 0) {
          resolve(allEntries);
        } else {
          allEntries.push(...entries);
          readBatch();
        }
      }, reject);
    }
    readBatch();
  });
}

// ── ZIP BUILDING ─────────────────────────────────────────────────

/**
 * Build a ZIP file from an array of { path, file } entries using JSZip.
 * Returns a File object with an auto-generated name.
 */
async function buildZipFromFiles(fileEntries, onProgress) {
  const zip = new JSZip();

  for (let i = 0; i < fileEntries.length; i++) {
    const entry = fileEntries[i];
    const arrayBuffer = await entry.file.arrayBuffer();
    zip.file(entry.path, arrayBuffer);
    onProgress('reading', 'Reading files... ' + (i + 1) + ' of ' + fileEntries.length,
      Math.round(((i + 1) / fileEntries.length) * 50));
  }

  onProgress('building', 'Building ZIP...', 50);
  const blob = await zip.generateAsync(
    { type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } },
    function (metadata) {
      var pct = 50 + Math.round(metadata.percent / 2);
      onProgress('building', 'Compressing... ' + Math.round(metadata.percent) + '%', pct);
    }
  );

  return new File([blob], generatePackageFilename(), { type: 'application/zip' });
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

dropZone.addEventListener('drop', async (e) => {
  e.preventDefault();
  dropZone.classList.remove('drag-over');

  const items = e.dataTransfer.items;
  if (!items || items.length === 0) return;

  // Single ZIP file → direct upload (existing behavior)
  if (items.length === 1 && items[0].kind === 'file') {
    const file = items[0].getAsFile();
    if (file && file.name.toLowerCase().endsWith('.zip')) {
      selectFile(file);
      return;
    }
  }

  // Folder/multi-file mode: read all entries and build ZIP
  uploadResult.hidden = true;
  progressWrap.hidden = false;
  setProgress('reading', 'Scanning folders...', 0);

  try {
    const fileEntries = await readDroppedItems(items);

    if (fileEntries.length === 0) {
      showResult('error', 'No files found in the dropped items.');
      progressWrap.hidden = true;
      return;
    }

    setProgress('reading', fileEntries.length + ' files found. Building ZIP...', 10);

    const zipFile = await buildZipFromFiles(fileEntries, setProgress);

    progressWrap.hidden = true;
    selectFile(zipFile);
  } catch (err) {
    showResult('error', 'Failed to read folders: ' + err.message);
    progressWrap.hidden = true;
  }
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
    const uploadFilename = generatePackageFilename();
    const urlResp = await apiCall('POST', '/api/upload-url', { filename: uploadFilename });

    // Step 3: Upload ZIP to R2
    setProgress('uploading', 'Uploading to R2...', 0);
    await uploadToR2(urlResp.uploadUrl, selectedFile);
    setProgress('uploading', 'Upload complete', 100);

    // Step 4: Update manifest
    setProgress('uploading', 'Updating manifest...', 100);
    await apiCall('PATCH', '/api/manifest', {
      packageFilename: uploadFilename,
      packageSizeBytes: selectedFile.size,
      packageChecksum: 'sha256:' + checksum,
      uploadedAt: new Date().toISOString(),
      orgName: clerk.organization && clerk.organization.name,
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

// ── ORG SWITCHER ──────────────────────────────────────────────────

function renderOrgDropdown() {
  while (orgDropdown.firstChild) {
    orgDropdown.removeChild(orgDropdown.firstChild);
  }

  const memberships = clerk.user.organizationMemberships;
  const activeOrgId = clerk.organization ? clerk.organization.id : null;

  memberships.forEach(function (mem) {
    var btn = document.createElement('button');
    btn.className = 'org-dropdown-item';
    if (mem.organization.id === activeOrgId) {
      btn.classList.add('active');
    }
    btn.textContent = mem.organization.name;
    btn.addEventListener('click', function () {
      if (mem.organization.id !== activeOrgId) {
        switchOrg(mem.organization.id).catch(console.error);
      }
      closeOrgDropdown();
    });
    orgDropdown.appendChild(btn);
  });
}

function toggleOrgDropdown() {
  if (orgDropdown.hidden) {
    renderOrgDropdown();
    orgDropdown.hidden = false;
    orgName.classList.add('open');
  } else {
    closeOrgDropdown();
  }
}

function closeOrgDropdown() {
  orgDropdown.hidden = true;
  orgName.classList.remove('open');
}

async function switchOrg(orgId) {
  clerkReady = false;
  await clerk.setActive({ organization: orgId });
}

document.addEventListener('click', function (e) {
  if (!orgDropdown.hidden && !e.target.closest('.org-switcher')) {
    closeOrgDropdown();
  }
});

document.addEventListener('keydown', function (e) {
  if (e.key === 'Escape' && !orgDropdown.hidden) {
    closeOrgDropdown();
  }
});

// ── BOOT ──────────────────────────────────────────────────────────
// initClerk() is called from index.html after the Clerk SDK loads.
