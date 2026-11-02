# Changelog

## 1.1.0

### Added

- A password file at a user-selected location, including mounted volumes.
- A remembered file path, with a startup choice to use or change it.
- Automatic saves when passwords are added, imported, removed, or cleared.
- Loading and merging of existing password lists when changing locations.
- Visible storage failures, retry controls, and an unsaved-changes prompt on quit.
- Protection against overwriting external changes to a loaded password file.
- UTF-8, BOM-marked UTF-16, and formatting-free RTF/RTFD import.
- Whitespace-separated import candidates, with exact UTF-8 duplicate detection.
- Sixteen password-storage and import integration tests, including a separate-process preference check.

### Preserved

- Literal spaces in manually entered passwords and the app's saved list.
- Candidate order and distinct Unicode byte sequences.
- The current in-memory list when a chosen volume is unavailable.

## 1.0.0

- Native SwiftUI/AppKit application for macOS.
- Finder drag-and-drop and multiple-file selection.
- Sequential archive processing with user-supplied password candidates.
- Red highlighting for the active password.
- Full archive testing before extraction.
- Default and per-archive extraction destinations.
- Separate output folders that preserve existing destination files.
- Path and link checks, temporary extraction, cancellation, and cleanup.
- Continued queue processing after errors or unsuccessful password attempts.
- Bundled universal 7-Zip 26.03 engine.
- Sixteen archive integration tests covering 7z, AES-ZIP, ZipCrypto, RAR4, RAR5, content integrity, collisions, cancellation, and cleanup.
