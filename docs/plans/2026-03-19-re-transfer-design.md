# Re-Transfer to USB Design

## Goal

Allow pilots to transfer the same downloaded update to additional USB drives, or redo a failed transfer.

## Context

The airplane can install updates from multiple USBs simultaneously for faster updates. Currently, after a successful transfer the app shows "Up to Date" with no way to transfer the same update again without a new server-side upload. The downloaded ZIP remains in the app's Documents directory and can be reused.

## Changes

### Transfer Complete Screen

- Keep existing "Done" button as primary (`.borderedProminent`)
- Add "Transfer to Another Drive" button below it in secondary style (`.bordered`)
- Tapping it opens the document picker and runs the same transfer flow
- After that second transfer completes, the user lands back on Transfer Complete again (can repeat as many times as needed)

### Up to Date Screen

- Add "Transfer Again" button below "Check for Updates" in secondary style (`.bordered`)
- Only visible when the downloaded ZIP still exists locally
- Tapping it opens the document picker and runs the same transfer flow

### State Logic

- No changes to `determineStatus()` — the status model stays the same
- `transferToUSB()` already works regardless of current state, so no changes needed there
- The only change is exposing the action in the UI in two places

### What We're NOT Doing

- No multi-drive tracking or history
- No changes to the wipe/extract logic
- No new status enum cases
