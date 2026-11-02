# ArchivBatch 1.2

**Drop. Try. Unpack. — in your language.**

ArchivBatch now opens in English by default, with a saved choice of nine interface languages. The archive queue, password list and automatic extraction workflow remain the same.

## New in 1.2

- **English by default**, regardless of the macOS language.
- A globe **Language** control in the window header and a **Language** menu in the menu bar.
- **German, French, Spanish, Brazilian Portuguese, Simplified Chinese, Japanese, Hindi and Arabic** alongside English.
- Immediate updates to app labels, statuses, messages, help and tooltips while idle. The selected language is remembered across launches.
- Right-to-left Arabic layout with exact filenames, paths and password content.
- Fourteen localization tests, bringing the regression suites to **46 tests**, plus native UI checks for every supported language.

Language switching is disabled while a batch is running. System-owned dialogs use the selected language after restarting the app.

## Download

Download **ArchivBatch-macOS-universal.zip**, unzip it and move **ArchivBatch.app** to Applications. **ArchivBatch-1.2.0-source.zip** contains the corresponding source; `SHA256SUMS.txt` contains the file checksums.

- Apple Silicon: macOS 12 or later.
- Intel: macOS 14 or later.
- Locally signed with an ad-hoc signature; not notarized by Apple. See the [installation guide](https://github.com/powermac84/archivbatch#install) for Apple's per-app opening instructions.

Existing password-file locations and password contents are preserved. The chosen password file remains plain text, and processing remains local. The app source is MIT-licensed; 7-Zip and the libarchive fixtures retain their separate licenses.

## Verification

The release includes 16 archive tests, 16 password-storage/import tests and 14 localization tests. These cover real encrypted archives, byte-exact contents, cancellation, storage across a restart, missing volumes, external file changes, complete translation catalogs, safe formatting, live language changes and Arabic layout direction. The native UI check renders all nine supported languages on Apple Silicon. The macOS workflow runs the regression suites and universal build on both Apple Silicon and Intel runners.
