# Archive engine integration tests

From the project directory, run `/bin/bash Tests/run-engine-tests.sh`. The harness compiles `ArchiveEngine.swift` and the test file, creates its own fixtures in a UUID-named subdirectory of `.build/`, and removes them after the run. Results are saved in `Reports/engine-tests.txt`.

7z, AES-ZIP, and unencrypted fixtures are created with the bundled 7-Zip engine. The legacy ZIP fixture uses `/usr/bin/zip`. Each successful test compares the actual extracted file contents. The cancellation test confirms that the extraction process is already running when it is cancelled. The cleanup test forces a failure after a real extraction, using subdirectories with restrictive permissions; the engine must remove its temporary directory while preserving an external symlink target and its permissions.

The small encrypted RAR4 and RAR5 archives come from the official regression tests of [libarchive](https://github.com/libarchive/libarchive). The original UU-encoded files and the upstream test description, including its license notices, are retained here:

- [RAR4 fixture](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar4_encrypted_filenames.rar.uu)
- [RAR5 fixture](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar5_encrypted_filenames.rar.uu)
- [Fixture description and license](https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar_encryption.c)

Both RAR fixtures use the test password `password` and contain `a.txt` through `d.txt`. Each file contains `This is from ` followed by its own filename.
