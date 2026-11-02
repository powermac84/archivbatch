import Foundation
import Darwin

enum EngineEvent {
    case attempt(Int?)
    case progress(String)
}

enum EngineOutcome {
    case success(URL, Int?)
    case noMatch(String)
    case failure(String)
    case cancelled
}

/// Runs only user-supplied candidates, in order. Call on a background queue.
final class ArchiveEngine {
    private let executable: URL
    private let stateLock = NSLock()
    private var currentProcess: Process?
    private var cancelled = false

    init(executable: URL) { self.executable = executable }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let process = currentProcess
        stateLock.unlock()
        if let process = process, process.isRunning {
            process.terminate()
            // 7-Zip handles SIGTERM cooperatively. Bound stop latency even while it is
            // decoding a large header or if its cancellation callback is not reached.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, weak process] in
                guard let self = self, let process = process else { return }
                self.stateLock.lock()
                if self.currentProcess === process && process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                self.stateLock.unlock()
            }
        }
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private struct CommandResult {
        let code: Int32
        let output: String
        let launchError: String?
    }

    private final class OutputBuffer {
        private let lock = NSLock()
        private var bytes = Data()
        private(set) var wasTruncated = false
        // Technical listings must never be silently cut: callers reject truncated output.
        private let limit = 32 * 1024 * 1024

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let available = limit - bytes.count
            if data.count > available { wasTruncated = true }
            if available > 0 { bytes.append(data.prefix(available)) }
        }

        func result() -> (String, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (String(decoding: bytes, as: UTF8.self), wasTruncated)
        }
    }

    private func run(_ arguments: [String]) -> CommandResult {
        if isCancelled { return CommandResult(code: 255, output: "", launchError: nil) }
        let process = Process()
        let pipe = Pipe()
        let buffer = OutputBuffer()
        let drained = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        stateLock.lock()
        if cancelled {
            stateLock.unlock()
            return CommandResult(code: 255, output: "", launchError: nil)
        }
        currentProcess = process
        do {
            // Holding the lock through launch closes the cancellation-before-run race.
            try process.run()
        } catch {
            currentProcess = nil
            stateLock.unlock()
            return CommandResult(code: -1, output: "", launchError: error.localizedDescription)
        }
        stateLock.unlock()
        pipe.fileHandleForWriting.closeFile()

        // Drain while the child runs: waiting before reading can fill the pipe and deadlock.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
            }
            pipe.fileHandleForReading.closeFile()
            drained.signal()
        }
        process.waitUntilExit()
        drained.wait()
        stateLock.lock()
        if currentProcess === process { currentProcess = nil }
        stateLock.unlock()
        let (output, truncated) = buffer.result()
        if truncated {
            return CommandResult(code: -1, output: output,
                                 launchError: "Die Archivliste oder Ausgabe ist zu groß (über 32 MB).")
        }
        return CommandResult(code: process.terminationStatus, output: output, launchError: nil)
    }

    private func arguments(command: String, archive: URL, password: String,
                           extra: [String] = []) -> [String] {
        [command, "-bd", "-bb0", "-sccUTF-8", "-spd", "-p" + password]
            + extra + ["--", archive.path]
    }

    private func diagnostic(_ result: CommandResult, passwords: [String]) -> String {
        var text = result.launchError ?? result.output
        for password in passwords.sorted(by: { $0.count > $1.count }) where !password.isEmpty {
            text = text.replacingOccurrences(of: password, with: "••••")
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let useful = lines.filter {
            let lower = $0.lowercased()
            return lower.contains("error") || lower.contains("wrong password")
                || lower.contains("cannot") || lower.contains("can not")
                || lower.contains("denied") || lower.contains("space")
                || lower.contains("unexpected") || lower.contains("unsupported")
        }
        let selected = useful.isEmpty ? Array(lines.suffix(5)) : Array(useful.prefix(5))
        return String(selected.joined(separator: "\n").prefix(1500))
    }

    /// An encrypted CRC/data error can mean either a wrong password or damaged data.
    /// Never claim that the CLI can distinguish those cases with certainty.
    private func definiteFailure(_ result: CommandResult) -> Bool {
        if result.launchError != nil { return true }
        if [Int32(7), 8, 255].contains(result.code) { return true }
        let knownStandalone = ["wrong password", "cannot open encrypted archive. wrong password?",
                               "headers error in encrypted archive. wrong password?",
                               "data error in encrypted file. wrong password?",
                               "crc failed in encrypted file. wrong password?",
                               "unexpected end of archive", "unexpected end of data",
                               "unsupported method", "unsupported feature", "is not archive",
                               "cannot open the file as archive", "can not open the file as archive",
                               "data error", "crc failed", "crc error"]
        let messages = result.output.components(separatedBy: .newlines).compactMap { line -> String? in
            let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
            if knownStandalone.contains(normalized) { return normalized }
            guard normalized.hasPrefix("error:") else { return nil }
            var message = String(normalized.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            // 7-Zip prints names either separately, after " : ", or before a
            // diagnostic after " : ". Never classify an archive/file name as an error.
            if message.hasPrefix("/") || message.hasPrefix("\\")
                || message.range(of: "^[a-z]:", options: .regularExpression) != nil {
                guard let separator = message.range(of: " : ") else { return nil }
                message = String(message[separator.upperBound...])
            }
            if let separator = message.range(of: " : ") {
                message = String(message[..<separator.lowerBound])
            }
            return message.isEmpty ? nil : message
        }
        let lower = messages.joined(separator: "\n")
        // These diagnostics establish an operational failure even if another entry
        // also reports a wrong password. They are matched only in actual error messages.
        let operationalErrors = ["permission denied", "operation not permitted", "no such file",
                                 "cannot find", "no space left", "not enough space", "disk full"]
        if operationalErrors.contains(where: { lower.contains($0) }) { return true }
        if lower.contains("wrong password") { return false }
        let archiveErrors = ["unsupported method", "unsupported feature", "unsupported archive",
                             "unexpected end of archive", "unexpected end of data",
                             "missing volume", "cannot open the file as archive"]
        if archiveErrors.contains(where: { lower.contains($0) }) { return true }
        if lower.contains("can not open") && lower.contains("as archive") { return true }
        if lower.contains("is not archive") { return true }
        if lower.contains("data error") || lower.contains("crc failed") || lower.contains("crc error") {
            return !lower.contains("encrypted")
        }
        return false
    }

    private func removeOwnStagingDirectory(_ directory: URL) {
        func makeDirectoriesDeletable(_ url: URL) {
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0,
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return }
            // AT_SYMLINK_NOFOLLOW also prevents following a link if an item changes
            // between lstat and the permission update. Files and links are left alone.
            guard Darwin.fchmodat(AT_FDCWD, url.path, mode_t(0o700), AT_SYMLINK_NOFOLLOW) == 0 else { return }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []) else { return }
            for child in children { makeDirectoriesDeletable(child) }
        }
        makeDirectoriesDeletable(directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private func unsafeListingReason(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[..<separator.lowerBound]).lowercased()
            let value = String(line[separator.upperBound...])
            let lower = value.lowercased()
            if key.contains("symbolic link") || key.contains("hard link") || key == "copy link" || key == "link" {
                if !value.isEmpty { return "Das Archiv enthält Links; diese werden aus Sicherheitsgründen nicht entpackt." }
            }
            if key == "attributes" || key == "mode" {
                if value.range(of: "(^|\\s)l[rwxstST-]{9}", options: .regularExpression) != nil {
                    return "Das Archiv enthält einen symbolischen Link."
                }
                if key == "mode", let octal = UInt32(value.trimmingCharacters(in: .whitespaces), radix: 8),
                   octal & 0o170000 == 0o120000 {
                    return "Das Archiv enthält einen symbolischen Link."
                }
            }
            if key == "characteristics" && (lower.contains("symlink") || lower.contains("symboliclink") || lower.contains("hardlink")) {
                return "Das Archiv enthält Links."
            }
            guard key == "path" else { continue }
            if value.isEmpty || value.hasPrefix("/") || value.hasPrefix("\\")
                || value.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
                return "Das Archiv enthält einen absoluten oder ungültigen Dateipfad."
            }
            let parts = value.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
            if parts.contains("..") || value.unicodeScalars.contains(where: { $0.value == 0 }) {
                return "Das Archiv enthält einen Pfad außerhalb seines Zielordners."
            }
        }
        return nil
    }

    private func validateExtractedTree(_ directory: URL) throws {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw NSError(domain: "ArchivBatch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Der entpackte Ordner konnte nicht geprüft werden."])
        }
        let prefix = directory.standardizedFileURL.path + "/"
        for case let file as URL in enumerator {
            if isCancelled { return }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true || !file.standardizedFileURL.path.hasPrefix(prefix) {
                throw NSError(domain: "ArchivBatch", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Das entpackte Archiv enthält einen unsicheren Link oder Pfad."])
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let type = attributes[.type] as? FileAttributeType,
               type != .typeRegular && type != .typeDirectory {
                throw NSError(domain: "ArchivBatch", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Das Archiv enthält eine nicht unterstützte Spezialdatei."])
            }
            if let count = attributes[.referenceCount] as? NSNumber, count.intValue > 1,
               attributes[.type] as? FileAttributeType == .typeRegular {
                throw NSError(domain: "ArchivBatch", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Das entpackte Archiv enthält einen Hardlink."])
            }
        }
        if let error = enumerationError { throw error }
    }

    func process(archive: URL, destinationRoot: URL, passwords: [String],
                 event: @escaping (EngineEvent) -> Void) -> EngineOutcome {
        if isCancelled { return .cancelled }
        let fileManager = FileManager.default
        let archive = archive.standardizedFileURL
        guard fileManager.isReadableFile(atPath: archive.path) else {
            return .failure("Das Archiv ist nicht lesbar oder existiert nicht mehr.")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: archive.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .failure("Bitte eine Archivdatei auswählen, keinen Ordner.")
        }
        if passwords.contains(where: { $0.unicodeScalars.contains(where: { $0.value == 0 }) }) {
            return .failure("Ein Passwort enthält ein nicht unterstütztes Nullzeichen.")
        }

        var lastResult = CommandResult(code: 2, output: "", launchError: nil)
        var acceptedPassword: String?
        var acceptedIndex: Int?
        let candidates: [(Int?, String)] = [(nil, "")] + passwords.enumerated().map { (Optional($0.offset), $0.element) }
        for (index, password) in candidates {
            if isCancelled { return .cancelled }
            event(.attempt(index))
            event(.progress(index == nil ? "Prüfe Archiv ohne Passwort …" : "Prüfe Passwort \((index ?? 0) + 1) von \(passwords.count) …"))
            let result = run(arguments(command: "t", archive: archive, password: password))
            if isCancelled { return .cancelled }
            lastResult = result
            if result.code == 0 && result.launchError == nil {
                acceptedPassword = password
                acceptedIndex = index
                break
            }
            if definiteFailure(result) {
                let detail = diagnostic(result, passwords: passwords)
                return .failure(detail.isEmpty ? "Das Archiv konnte nicht geprüft werden (Fehler \(result.code))." : detail)
            }
        }
        guard let password = acceptedPassword else {
            let detail = diagnostic(lastResult, passwords: passwords)
            return .noMatch("Kein passendes Passwort gefunden; bei verschlüsselten Daten kann auch ein beschädigtes Archiv die Ursache sein."
                            + (detail.isEmpty ? "" : "\n" + detail))
        }

        event(.progress("Prüfe Dateipfade …"))
        let listing = run(arguments(command: "l", archive: archive, password: password,
                                    extra: ["-slt", "-ba"]))
        if isCancelled { return .cancelled }
        guard listing.code == 0 && listing.launchError == nil else {
            let detail = diagnostic(listing, passwords: passwords)
            return .failure(detail.isEmpty ? "Der Inhalt des Archivs konnte nicht sicher geprüft werden." : detail)
        }
        if let reason = unsafeListingReason(listing.output) { return .failure(reason) }

        var staging: URL?
        defer {
            // This is exclusively the fresh UUID folder created by this operation.
            if let staging = staging { removeOwnStagingDirectory(staging) }
        }
        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            let root = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
            var rootIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue,
                  fileManager.isWritableFile(atPath: root.path) else {
                return .failure("Der Zielordner ist nicht beschreibbar.")
            }
            let temporary = root.appendingPathComponent(".ArchivBatch-" + UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            staging = temporary
            if isCancelled { return .cancelled }
            event(.progress(acceptedIndex == nil ? "Entpacke …" : "Passwort passt. Entpacke …"))
            let extraction = run(arguments(command: "x", archive: archive, password: password,
                                            extra: ["-aou", "-y", "-snl-", "-snh-", "-o" + temporary.path]))
            if isCancelled { return .cancelled }
            guard extraction.code == 0 && extraction.launchError == nil else {
                let detail = diagnostic(extraction, passwords: passwords)
                return .failure(detail.isEmpty ? "Entpacken fehlgeschlagen (Fehler \(extraction.code))." : detail)
            }
            try validateExtractedTree(temporary)
            if isCancelled { return .cancelled }
            var name = archive.deletingPathExtension().lastPathComponent
            if name.isEmpty || name == "." || name == ".." { name = "Archiv" }
            // Never merge into an existing directory or overwrite an existing file.
            for suffix in 1...10000 {
                if isCancelled { return .cancelled }
                let finalName = suffix == 1 ? name : "\(name) (\(suffix))"
                let target = root.appendingPathComponent(finalName, isDirectory: true)
                if fileManager.fileExists(atPath: target.path) { continue }
                do {
                    try fileManager.moveItem(at: temporary, to: target)
                    staging = nil
                    return .success(target, acceptedIndex)
                } catch {
                    // Another process may have taken the name after the existence check.
                    if fileManager.fileExists(atPath: target.path) { continue }
                    throw error
                }
            }
            return .failure("Es konnte kein freier Name für den Ausgabeordner gefunden werden.")
        } catch {
            let result = CommandResult(code: -1, output: "", launchError: error.localizedDescription)
            return .failure(diagnostic(result, passwords: passwords))
        }
    }
}
