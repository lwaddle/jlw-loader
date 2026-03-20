# Hide Update Filename from Main View

## Problem

The update available view shows the raw package filename (e.g., `update-2026-03-19-200547.zip`), which is not meaningful to pilots.

## Design

Remove the filename display from `updateAvailableView` in `MainView.swift`. The upload time and download size already provide sufficient context.

### Before

```
New Update Available
update-2026-03-19-200547.zip
Uploaded 3 hours ago
187.2 MB download
[Download Update]
```

### After

```
New Update Available
Uploaded 3 hours ago
187.2 MB download
[Download Update]
```

## Scope

- Delete the `if let filename` block from `MainView.swift` (~4 lines)
- No model, API, or other view changes needed
