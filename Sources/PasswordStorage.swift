import AppKit
import Foundation
import Darwin

enum PasswordStorageError: LocalizedError {
    case unsupportedText
    case invalidPath
    case unavailableDirectory
    case unsuitableFile
    case invalidPassword
    case externalChange

    var errorDescription: String? {
        switch self {
        case .unsupportedText:
            return "Die Datei ist keine lesbare UTF-8-, UTF-16- oder RTF-Textdatei."
        case .invalidPath:
            return "Bitte einen lokalen Dateipfad auf dem gewünschten Volume wählen."
        case .unavailableDirectory:
            return "Der Ordner der Passwortliste ist nicht verfügbar. Bitte das Volume verbinden oder einen anderen Speicherort wählen."
        case .unsuitableFile:
            return "Die Passwortliste muss eine normale Datei sein, kein Ordner oder symbolischer Link."
        case .invalidPassword:
            return "Ein Passwort enthält einen Zeilenumbruch oder ein Nullzeichen und kann so nicht gespeichert werden."
        case .externalChange:
            return "Die Passwortdatei wurde außerhalb der App geändert oder gelöscht. Bitte erneut laden, um vorhandene und aktuelle Passwörter zusammenzuführen."
        }
    }
}

enum PasswordText {
    private static func withoutBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    static func decodePlainText(_ data: Data) throws -> String {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let decoded = text.map(withoutBOM), !decoded.contains("\0") else {
            throw PasswordStorageError.unsupportedText
        }
        return decoded
    }

    /// Imported text uses every contiguous sequence of non-whitespace characters.
    /// Punctuation, case, and Unicode characters remain part of each candidate.
    static func tokens(in text: String) -> [String] {
        withoutBOM(text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The app's own file keeps one exact password per line, including manually
    /// entered spaces. This differs from importing arbitrary candidate text.
    static func storedLines(in text: String) -> [String] {
        withoutBOM(text).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func importCandidates(from url: URL) throws -> [String] {
        guard url.isFileURL else { throw PasswordStorageError.invalidPath }
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "rtf" || ext == "rtfd" {
            let kind: NSAttributedString.DocumentType = ext == "rtfd" ? .rtfd : .rtf
            let attributed = try NSAttributedString(url: url,
                options: [.documentType: kind], documentAttributes: nil)
            text = attributed.string.replacingOccurrences(of: "\u{FFFC}", with: " ")
        } else {
            text = try decodePlainText(Data(contentsOf: url))
        }
        return tokens(in: text)
    }
}

final class PasswordListStorage {
    private let defaults: UserDefaults
    private var snapshots: [String: Data] = [:]
    private static let pathKey = "local.archivbatch.passwordListPath"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var rememberedURL: URL? {
        guard let path = defaults.string(forKey: Self.pathKey), path.hasPrefix("/"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func remember(_ url: URL) {
        guard url.isFileURL else { return }
        defaults.set(url.standardizedFileURL.path, forKey: Self.pathKey)
    }

    func load(from url: URL) throws -> [String] {
        guard url.isFileURL else { throw PasswordStorageError.invalidPath }
        try ensureRegularFileIfPresent(url)
        let data = try Data(contentsOf: url)
        let text = try PasswordText.decodePlainText(data)
        var seen = Set<Data>()
        let values = PasswordText.storedLines(in: text).filter { seen.insert(Data($0.utf8)).inserted }
        snapshots[url.standardizedFileURL.path] = data
        return values
    }

    /// Writes through a private sibling file, then renames atomically. An absent
    /// mount/parent is an error: this never recreates a volume path locally.
    func save(_ values: [String], to url: URL) throws {
        guard url.isFileURL else { throw PasswordStorageError.invalidPath }
        guard !values.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else {
            throw PasswordStorageError.invalidPassword
        }
        let target = url.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw PasswordStorageError.unavailableDirectory
        }
        let existingMode = try ensureRegularFileIfPresent(target)
        try validateSnapshot(at: target, fileExists: existingMode != nil)
        let temporary = parent.appendingPathComponent(".ArchivBatch-Passwoerter-" + UUID().uuidString + ".tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var renamed = false
        defer {
            try? handle.close()
            if !renamed { try? FileManager.default.removeItem(at: temporary) }
        }
        let text = values.isEmpty ? "" : values.joined(separator: "\n") + "\n"
        let data = Data(text.utf8)
        try handle.write(contentsOf: data)
        if Darwin.fchmod(fd, (existingMode ?? mode_t(0o600)) & mode_t(0o777)) != 0 { throw posixError() }
        try handle.synchronize()
        try handle.close()
        // Reject a symlink or directory that appeared while the file was written.
        let finalMode = try ensureRegularFileIfPresent(target)
        try validateSnapshot(at: target, fileExists: finalMode != nil)
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw posixError() }
        renamed = true
        snapshots[target.path] = data
    }

    private func validateSnapshot(at url: URL, fileExists: Bool) throws {
        guard let expected = snapshots[url.standardizedFileURL.path] else { return }
        guard fileExists else { throw PasswordStorageError.externalChange }
        let current = try Data(contentsOf: url)
        guard current == expected else { throw PasswordStorageError.externalChange }
    }

    @discardableResult
    private func ensureRegularFileIfPresent(_ url: URL) throws -> mode_t? {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw PasswordStorageError.unsuitableFile }
            return info.st_mode
        }
        let error = errno
        guard error == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        return nil
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
