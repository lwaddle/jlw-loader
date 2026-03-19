# Org Switcher Design

**Date:** 2026-03-19
**Status:** Approved

## Context

The web uploader displays the Clerk org slug (e.g., `jlw-aviation-1773805823527407261`) in the topbar. Users manage multiple aircraft, each represented as a Clerk organization. They need a way to switch between orgs and see clean display names.

## Design

### Org Name Display

- Display `clerk.organization.name` instead of the org slug in the topbar
- Single org: static text, no dropdown affordance
- Multiple orgs: clickable org name with a chevron icon indicating a dropdown

### Dropdown Behavior

- **Trigger:** Click org name to toggle dropdown open/closed
- **Contents:** List of all orgs from `clerk.user.organizationMemberships`, showing `organization.name` for each. Active org is highlighted.
- **Switching:** Clicking a different org calls `clerk.setActive({ organization: orgId })`, closes the dropdown, and reloads dashboard data
- **Dismissal:** Click outside or press Escape
- **Positioning:** Anchored below org name, left-aligned, styled to match existing dark theme

### Data Flow on Org Switch

1. User clicks a different org in the dropdown
2. `clerk.setActive({ organization: selectedOrg.id })` is called
3. Existing `clerk.addListener()` callback fires, calling `handleClerkState()`
4. `handleClerkState()` fetches a new JWT and loads the manifest — dashboard refreshes with new org data
5. Topbar org name updates to `clerk.organization.name`

### What's NOT Changing

- No backend changes needed — already multi-tenant and org-scoped
- No new API endpoints
- No changes to auth flow

## Approach

Custom vanilla JS dropdown (not Clerk's `OrganizationSwitcher` widget) to maintain styling consistency and avoid unnecessary complexity.

## Tech Stack

- Vanilla JS (matches existing codebase)
- Vanilla CSS with existing design tokens
- Clerk JS SDK v5 (`clerk.setActive()`, `clerk.user.organizationMemberships`)
