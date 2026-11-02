# Third-party notices

The [MIT license](LICENSE) applies to ArchivBatch's original application code and project documentation. It does not replace the licenses of the third-party components and resources below.

## 7-Zip 26.03

ArchivBatch bundles the official `7zz` console executable from [7-Zip](https://www.7-zip.org/), copyright © 1999–2026 Igor Pavlov. It provides archive testing and extraction as a separate executable.

7-Zip's code is principally licensed under GNU LGPL 2.1 or later. Some portions additionally carry the unRAR license restriction; other portions use BSD 2-clause and BSD 3-clause licenses. The complete supplied notices, including their copyright holders and the unRAR restriction, are preserved in [Vendor/License.txt](Vendor/License.txt). The complete LGPL text is in [LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt).

The original distributions for the bundled version are:

- [Official macOS binary distribution](https://www.7-zip.org/a/7z2603-mac.tar.xz)
- [Matching original source distribution](https://www.7-zip.org/a/7z2603-src.7z), also included as `Vendor/7z2603-src.7z`

The build copies these license notices, the manual, and the matching source archive into the app's `Contents/Resources/7-Zip/` directory. Redistribution of ArchivBatch must retain them. The bundled 7-Zip component is not relicensed under MIT.

The unRAR restriction prohibits using the relevant unRAR sources to develop a RAR/WinRAR-compatible compression algorithm. Read the complete original restriction in `Vendor/License.txt` when reusing those sources.

## libarchive regression fixtures

The small RAR4 and RAR5 encrypted-filename fixtures in `Tests/` come from the official [libarchive regression suite](https://github.com/libarchive/libarchive). The original UU-encoded files are included alongside their decoded test fixtures.

Their upstream test description and BSD-style notice are preserved, unchanged, in [Tests/rar-upstream-test.c](Tests/rar-upstream-test.c). [Tests/README.md](Tests/README.md) links to each original fixture and describes its synthetic contents and public test password. Retain those notices when redistributing these test materials.

## Project illustrations and screenshots

The launch illustrations in `docs/images/` were generated specifically for ArchivBatch using AI-assisted image generation. The project-specific artwork is included under the MIT license to the extent that copyright applies. Generation prompts are recorded in [docs/visual-prompts.md](docs/visual-prompts.md).

Application screenshots show the real ArchivBatch interface with synthetic demonstration data.

## Apple platform resources

ArchivBatch uses Apple's AppKit, SwiftUI, and system symbols through the macOS SDK. Those platform resources remain subject to Apple's applicable terms and are not relicensed by this repository. The icon rendering utility in `Tools/Icon.swift` uses macOS system symbols; the MIT license covers the original utility code, not ownership of Apple's underlying symbol designs.
