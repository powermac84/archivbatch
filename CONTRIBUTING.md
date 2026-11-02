# Contributing to ArchivBatch

Small, focused improvements are welcome. A good contribution keeps the native workflow clear and preserves archive contents, password bytes, and existing user files.

## Before opening a pull request

For a bug, include the app version, macOS version, chip type, steps to reproduce, and the result you expected. If an archive is needed, create a small synthetic example with a test password. Use [GitHub issues](https://github.com/powermac84/archivbatch/issues) for reports and feature proposals.

For larger changes, open an issue first so the approach can be discussed. Keep pull requests focused and explain the resulting behavior and relevant validation.

## Build

Use a Mac with Xcode or the Xcode Command Line Tools installed:

```sh
/bin/bash build.sh
```

The universal application is written to `dist/ArchivBatch.app`. The build signs it ad hoc and checks both architectures and the app signature. Building does not install the app.

## Validation

Run the suites relevant to your change:

```sh
/bin/bash Tests/run-engine-tests.sh
/bin/bash Tests/run-password-tests.sh
```

For changes to the queue, storage integration, or interface, run the native UI check from a logged-in graphical macOS session:

```sh
/bin/bash Tools/run-ui-check.sh
```

It opens a temporary test window, processes generated fixtures, checks the model, and saves interface images in `Reports/`. The password-preference test uses its own temporary settings suite. A restricted execution environment may block preference persistence or window creation; run these tests in a normal local macOS session.

The repository includes small RAR fixtures from libarchive. Preserve their source and license notices in [Tests/README.md](Tests/README.md).

## Implementation priorities

- Keep password content exact. Imported whitespace is a delimiter; manually entered spaces are part of the password.
- Preserve candidate order and distinguish different UTF-8 byte sequences.
- Continue the batch after an unsuccessful or malformed archive.
- Preserve existing destination files and keep partial extraction out of finished output.
- Treat missing volumes and external edits as storage errors that the user can resolve.
- Keep processing local and user-controlled.

The application interface is currently German. English documentation should use the real German control label where it helps someone find the action.

## Licensing

Contributions to the app's original source are provided under its [MIT license](LICENSE). The bundled 7-Zip engine and the libarchive test fixtures retain their separate licenses and notices. Changes to bundled third-party components should include the corresponding source and updated attribution.
