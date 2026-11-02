# ArchivBatch 1.1

**Drop. Try. Unpack.**

A native macOS utility for working through a queue of archives with the passwords you already have.

Drag archives in from Finder, add your password candidates, and press Start. ArchivBatch tests each archive, highlights the current password in red, and extracts successful archives into separate folders. Unmatched or damaged archives are marked while the queue keeps moving.

## In this release

- Finder drag-and-drop for one file or a whole batch.
- Sequential testing and extraction for 7z, ZIP, RAR, and RAR5 through bundled 7-Zip 26.03.
- Password entry with Enter and whitespace-based import from UTF-8, UTF-16, RTF, or RTFD text.
- A saved password list on a location or mounted volume you choose, with automatic saving and a remembered path.
- A default extraction folder plus individual destinations per archive.
- Stop and restart, collision-safe output folders, and visible results.

## Download

Download **ArchivBatch-macOS-universal.zip**, unzip it, and move **ArchivBatch.app** to Applications. `SHA256SUMS.txt` contains the file checksum.

- Apple Silicon: macOS 12 or later.
- Intel: macOS 14 or later.
- App interface: German. Documentation: English.
- Locally signed with an ad-hoc signature; not notarized by Apple. See the [installation guide](https://github.com/powermac84/archivbatch#install) for Apple's per-app opening instructions.

The password file is saved as plain text at the selected location. Archive processing is local. The application source is MIT-licensed; the bundled 7-Zip component and libarchive fixtures retain their original licenses.

## Verification

The release passes 16 archive integration tests and 16 password-storage/import tests, plus a native UI/model check on Apple Silicon. Both executable architectures and the deep app signature are verified. Intel hardware runtime verification is not part of this local release check; the repository's macOS workflow additionally runs the suites on both runner architectures.
