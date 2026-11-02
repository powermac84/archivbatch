# Using ArchivBatch

ArchivBatch works through archives with a list of possible passwords you provide. Processing takes place on your Mac, using the bundled 7-Zip engine.

## Start a batch

1. Choose the file that will hold your password list. You can put it on your Mac or a mounted volume.
2. Choose the default folder for extracted output.
3. Drag archives from Finder into the archive pane, or click **Add**.
4. Add password candidates with Return, or click **Import text…**.
5. Optionally click the folder control in an archive's row to give it a different destination.
6. Click **Start**.

ArchivBatch first checks whether the archive opens without a password. It then tests candidates in list order. The active candidate turns red. A successful full archive test is followed by extraction; then the next archive begins.

For a multipart archive, add the **first part** and keep every remaining part next to it in Finder. Supported formats and encryption methods are determined by the bundled 7-Zip version.

## Choosing a language

ArchivBatch starts in **English**, regardless of your macOS language. Use the globe **Language** control in the window header or the **Language** menu in the menu bar to choose:

| Language | Name shown in the menu |
| --- | --- |
| English | English |
| German | Deutsch |
| French | Français |
| Spanish | Español |
| Brazilian Portuguese | Português (Brasil) |
| Simplified Chinese | 简体中文 |
| Japanese | 日本語 |
| Hindi | हिन्दी |
| Arabic | العربية |

Your choice is saved for the next launch. App labels, statuses, messages, help and tooltips update immediately while the app is idle. Language switching is disabled during a running batch. System-owned dialogs use the selected language after restarting the app.

Arabic uses a right-to-left layout. Filenames, paths and password content remain unchanged when you switch languages.

## Interface reference

The following labels are from the default English interface.

| Control or status | Meaning |
| --- | --- |
| **Archives / Add** | Archive queue / add files |
| **DEFAULT DESTINATION / Change…** | Default extraction folder / change it |
| **Passwords** | Password candidates |
| **Import text…** | Import candidates from a text document |
| **Password file / Location…** | Saved password file / choose its location |
| **Reload / save again** | Retry loading or saving |
| **Clear** | Clear the password list and save the empty list |
| **Start / Stop** | Start / stop processing |
| **Done / Show in Finder** | Extracted successfully / reveal output in Finder |
| **No match** | No candidate completed the archive test successfully |
| **Error / Stopped** | Processing error / stopped |

The context menu on a completed archive can copy its matching password. Keep the password pane in mind when sharing screenshots.

## Importing text

Plain-text imports accept **UTF-8** and **BOM-marked UTF-16**. **RTF and RTFD** imports use the document's text and discard formatting.

Every continuous sequence of non-whitespace characters becomes a candidate. Spaces, tabs, line breaks, paragraph breaks, and other Unicode whitespace separate candidates.

For example:

```text
alpha beta

gamma	Delta!
```

This produces four candidates: `alpha`, `beta`, `gamma`, and `Delta!`. In the example, the gap before `Delta!` is a tab. Punctuation and capitalization are kept. An identical UTF-8 candidate appears once; distinct Unicode byte sequences remain distinct candidates.

A password containing literal spaces should be entered **manually**. Manually entered passwords retain leading, trailing, and internal spaces in the app's saved list. The saved file uses one exact password per line; loading that file at startup preserves those spaces. Importing it through **Import text…** applies the whitespace-splitting rule instead.

## Keeping a password list on a volume

At first launch, choose a password-file location. The app remembers that path and offers to use or change it on subsequent launches. To change it later, click **Location…** under **Password file**.

Adding, importing, removing, and clearing entries automatically updates the chosen file. The file is plain text. Its path, rather than the password contents, is stored in the app's preferences.

When you switch to another location, current entries are merged with entries already present there. Unreadable files are not replaced by empty lists.

If the volume is disconnected or a write fails:

- The current list stays in memory.
- The storage status reports that changes have not been saved.
- Reconnect the volume and choose **Reload / save again**, or select another location.
- The app asks before quitting with unsaved changes.

If another program changes the saved file, ArchivBatch reports the conflict. An explicit reload merges the file's contents with the current list before another save.

## Output and results

Successful output is placed in a separate folder for each archive. Existing files in your destination are preserved. A folder-name collision gets a new name; duplicate paths inside an archive are extracted under separate names.

The engine checks listed paths before extraction, rejects links and unsafe paths, extracts into a temporary folder, checks the extracted tree, and moves successful results into the final output location. Failed or cancelled attempts are not presented as completed output.

**No match** can also result from damaged encrypted data: a failed encrypted checksum does not establish whether the password was wrong or the archive was damaged. **Error** identifies a processing failure, such as an unreadable file or unsupported content. The queue continues after either result.

**Stop** cancels the current operation. A subsequent **Start** processes unfinished or unsuccessful entries again; completed entries are skipped. Completed output remains available in Finder.

## Installing a release

Use the [latest release](https://github.com/powermac84/archivbatch/releases/latest), unzip the universal download, and move **ArchivBatch.app** to Applications.

Apple Silicon requires macOS 12 or later; Intel requires macOS 14 or later. The app uses an ad-hoc signature and is not Apple-notarized. macOS may require per-app approval; Apple's [opening instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac) describe the process.
