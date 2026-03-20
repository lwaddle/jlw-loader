# Settings View Redesign

## Overview

Restructure the iOS SettingsView from a single-purpose aircraft manager into a proper sectioned settings screen with support links, sign-out, and version info.

## Target Users

Primarily pilots — non-technical users who need a clean, familiar iOS experience. Settings should be simple with no unnecessary toggles.

## Design

The settings view uses a grouped `List` with four logical areas:

### Section 1: Aircraft

- Header: "Aircraft"
- Lists all saved aircraft (orgs) with checkmark on the active one
- Tap a row to switch active aircraft
- Swipe-to-delete on each row to remove an aircraft
- "Add Aircraft" button in the top-right toolbar
- No changes from current behavior

### Section 2: Support

- Header: "Support"
- **Support** row — opens https://lwaddle.github.io/jlw-loader/support in system browser, with chevron disclosure indicator
- **Privacy Policy** row — opens https://lwaddle.github.io/jlw-loader/privacy in system browser, with chevron disclosure indicator

### Section 3: Account

- Header: "Account"
- **Sign Out** button — red-tinted text
- Tapping shows a confirmation alert: "Sign out of all aircraft?" with Cancel and Sign Out actions
- On confirm: clears all credentials from Keychain and returns to AccessCodeView

### Section 4: Version Footer

- Not a grouped section — displayed as centered, gray, small footer text below the Account section
- Format: "JLW Loader v1.0.0 (1)" using values from the app bundle
- Non-interactive

## Future Considerations

- APN notification toggles may be added later — would go in a new "Notifications" section between Support and Account
