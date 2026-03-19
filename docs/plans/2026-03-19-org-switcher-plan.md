# Org Switcher Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add org name display and org switching dropdown to the web uploader topbar.

**Architecture:** Replace the slug-based org display with `clerk.organization.name`. Add a custom dropdown that lists all user orgs and calls `clerk.setActive()` to switch. The existing listener-driven flow handles dashboard refresh automatically.

**Tech Stack:** Vanilla JS, Vanilla CSS, Clerk JS SDK v5

---

### Task 1: Display org name instead of slug

**Files:**
- Modify: `web-uploader/app.js:170-172` (renderManifest function)

**Step 1: Update org name display to use Clerk organization name**

In `renderManifest()` at line 172, change:
```javascript
orgName.textContent = m.orgId || 'Unknown';
```
to:
```javascript
orgName.textContent = (clerk.organization && clerk.organization.name) || m.orgId || 'Unknown';
```

**Step 2: Verify in browser**

Run: Open the web uploader, sign in, confirm the topbar shows the org's display name (e.g., "JLW Aviation") instead of the slug.

**Step 3: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: display org name instead of slug in topbar"
```

---

### Task 2: Add chevron indicator for multi-org users

**Files:**
- Modify: `web-uploader/app.js:170-172` (renderManifest function)
- Modify: `web-uploader/style.css:301-305` (topbar-org styles)

**Step 1: Add conditional chevron after org name**

In `renderManifest()`, after setting `orgName.textContent`, add logic to show a chevron when the user has multiple orgs:

```javascript
// Show dropdown affordance if user has multiple orgs
const memberships = clerk.user.organizationMemberships;
if (memberships && memberships.length > 1) {
  orgName.classList.add('has-switcher');
} else {
  orgName.classList.remove('has-switcher');
}
```

**Step 2: Add CSS for the chevron**

In `style.css`, update `.topbar-org` and add chevron styles:

```css
.topbar-org.has-switcher {
  cursor: pointer;
  user-select: none;
}

.topbar-org.has-switcher::after {
  content: '';
  display: inline-block;
  width: 0;
  height: 0;
  margin-left: 8px;
  border-left: 4px solid transparent;
  border-right: 4px solid transparent;
  border-top: 5px solid var(--green);
  vertical-align: middle;
  transition: transform 0.2s;
}

.topbar-org.has-switcher.open::after {
  transform: rotate(180deg);
}
```

**Step 3: Verify in browser**

Confirm: If user has 1 org, no chevron. If user has 2+ orgs, chevron appears next to org name.

**Step 4: Commit**

```bash
git add web-uploader/app.js web-uploader/style.css
git commit -m "feat: add chevron indicator for multi-org users"
```

---

### Task 3: Build the org switcher dropdown

**Files:**
- Modify: `web-uploader/index.html:38` (add dropdown container)
- Modify: `web-uploader/app.js` (add dropdown logic)
- Modify: `web-uploader/style.css` (add dropdown styles)

**Step 1: Add dropdown container to HTML**

In `index.html`, wrap the org name and add a dropdown container. Replace line 38:

```html
<span id="org-name" class="topbar-org"></span>
```

with:

```html
<div class="org-switcher">
  <span id="org-name" class="topbar-org"></span>
  <div id="org-dropdown" class="org-dropdown" hidden></div>
</div>
```

**Step 2: Add dropdown CSS**

Add to `style.css` after the `.topbar-org` block (after line 305):

```css
.org-switcher {
  position: relative;
}

.org-dropdown {
  position: absolute;
  top: calc(100% + 8px);
  left: 0;
  min-width: 200px;
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  z-index: 100;
  overflow: hidden;
  animation: dropdownIn 0.15s ease-out;
}

@keyframes dropdownIn {
  from { opacity: 0; transform: translateY(-4px); }
  to   { opacity: 1; transform: translateY(0); }
}

.org-dropdown-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 14px;
  font-size: 14px;
  font-family: var(--font-mono);
  color: var(--text-secondary);
  cursor: pointer;
  transition: background 0.15s, color 0.15s;
  border: none;
  background: none;
  width: 100%;
  text-align: left;
}

.org-dropdown-item:hover {
  background: var(--bg-hover);
  color: var(--text-primary);
}

.org-dropdown-item.active {
  color: var(--green);
}

.org-dropdown-item.active::after {
  content: '\2713';
  font-size: 12px;
  color: var(--green);
}

.org-dropdown-item + .org-dropdown-item {
  border-top: 1px solid var(--border-subtle);
}
```

**Step 3: Add dropdown toggle and render logic to app.js**

Add a new section in `app.js` after the DOM REFS block (after line 46). Add a DOM ref:

```javascript
const orgDropdown = document.getElementById('org-dropdown');
```

Add the dropdown functions before the `// ── BOOT` section:

```javascript
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
        switchOrg(mem.organization.id);
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
```

**Step 4: Wire up click handler on org name**

In `renderManifest()`, after the chevron logic, add the click handler (only once):

```javascript
if (memberships && memberships.length > 1) {
  orgName.classList.add('has-switcher');
  orgName.onclick = toggleOrgDropdown;
} else {
  orgName.classList.remove('has-switcher');
  orgName.onclick = null;
}
```

**Step 5: Add click-outside and Escape dismissal**

Add after the org switcher functions:

```javascript
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
```

**Step 6: Verify in browser**

1. Sign in with a user that has 2+ orgs
2. Click org name — dropdown appears with all orgs listed
3. Active org has a checkmark
4. Click a different org — dashboard reloads with new org's data
5. Click outside or press Escape — dropdown closes
6. Sign in with a single-org user — no chevron, no dropdown

**Step 7: Commit**

```bash
git add web-uploader/index.html web-uploader/app.js web-uploader/style.css
git commit -m "feat: add org switcher dropdown in topbar"
```

---

### Task 4: Handle org switch state reset

**Files:**
- Modify: `web-uploader/app.js:65-92` (handleClerkState function)

**Step 1: Ensure clean state on org switch**

The existing `handleClerkState()` uses a `clerkReady` guard to prevent re-entry. When `switchOrg()` sets `clerkReady = false` and calls `setActive()`, the listener fires and `handleClerkState()` runs again. But we need to make sure the dashboard fully reloads.

Update `handleClerkState()` to close the dropdown and reset upload state on org switch:

```javascript
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
```

Note: The key change is moving `if (clerkReady) return` AFTER setting the org, and adding `closeOrgDropdown()` and `resetUploadUI()` before `loadDashboard()`.

**Step 2: Verify in browser**

1. Upload a file but don't submit
2. Switch orgs
3. Confirm: upload form resets, new org's data loads cleanly

**Step 3: Commit**

```bash
git add web-uploader/app.js
git commit -m "feat: reset upload state on org switch"
```
