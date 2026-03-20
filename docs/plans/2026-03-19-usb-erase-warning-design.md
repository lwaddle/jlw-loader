# USB Erase Warning Alert

## Problem

When a pilot selects a USB drive for transfer, the app immediately wipes the drive and writes data with no confirmation. There is no opportunity to cancel if the wrong drive was selected.

## Design

### Approach: SwiftUI `.alert()` modifier

Intercept the document picker result, store the selected URL, and present a native SwiftUI alert before proceeding.

### Changes

**AppState.swift:**
- Add `@Published var showEraseConfirmation = false`
- Add `var pendingDriveURL: URL? = nil`
- When document picker returns a URL, store it in `pendingDriveURL` and set `showEraseConfirmation = true` instead of calling `transferToUSB` directly
- Extract drive name from URL volume resource values for the alert message

**MainView.swift:**
- Add `.alert("Erase USB Drive?", isPresented: $appState.showEraseConfirmation)` modifier
- Message: "All data on [DriveName] will be permanently erased and replaced with the database update."
- Destructive button: "Erase & Transfer" → calls `transferToUSB(driveURL:)` with pending URL
- Cancel button: "Cancel" → clears `pendingDriveURL`

### Flow

1. User taps "Select USB Drive" → document picker opens
2. User picks a drive → URL stored, alert appears
3. User taps "Cancel" → returns to ready state
4. User taps "Erase & Transfer" → existing `transferToUSB` runs as before
