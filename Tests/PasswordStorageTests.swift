import Foundation
import AppKit
import Darwin

private struct PasswordCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct PasswordStorageTests {
    static let fm = FileManager.default
    static var lines: [String] = []
    static var failures = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw PasswordCheckFailure(description: reason) }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            lines.append("PASS  \(name)")
        } catch {
            failures += 1
            lines.append("FAIL  \(name): \(error)")
        }
        print(lines.last!)
    }

    static func expectThrow(_ reason: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch { return }
        throw PasswordCheckFailure(description: reason)
    }

    static func main() throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--read-remembered-path" {
            let defaults = UserDefaults(suiteName: CommandLine.arguments[2])!
            let store = PasswordListStorage(defaults: defaults)
            if store.rememberedURL?.standardizedFileURL.path == CommandLine.arguments[3] { exit(0) }
            print("Observed remembered path: \(store.rememberedURL?.path ?? "nil"); expected: \(CommandLine.arguments[3])")
            exit(1)
        }
        let root = fm.temporaryDirectory.appendingPathComponent("ArchivBatch-password-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let suiteName = "local.archivbatch.tests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PasswordCheckFailure(description: "Cannot create isolated preferences")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? fm.removeItem(at: root)
        }

        test("Whitespace import splits spaces, tabs, LF, CRLF, NBSP and Unicode spacing") {
            let actual = PasswordText.tokens(in: " \talpha beta\r\ngamma\ndelta\repsilon\u{00A0}zeta\u{2003}eta\u{2028}theta \n")
            try check(actual == ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"], "Whitespace did not separate all contiguous tokens")
        }

        test("Import preserves punctuation, case and contiguous Unicode sequences") {
            let expected = ["pa$$!", "A=B", "foo:bar", "MixCase", "mixcase", "🔑pass", "äÖß", "a,b;c"]
            try check(PasswordText.tokens(in: expected.joined(separator: " \n\t")) == expected, "Non-whitespace content changed")
        }

        test("UTF-8 BOM is excluded and whitespace-only input adds no passwords") {
            try check(PasswordText.tokens(in: "\u{FEFF}alpha beta") == ["alpha", "beta"], "BOM became part of first candidate")
            try check(PasswordText.tokens(in: " \t\r\n\u{00A0}\u{2003}").isEmpty, "Empty candidates were emitted")
        }

        test("UTF-8 and BOM-marked UTF-16 files produce the same import candidates") {
            let original = "eins zwei\n🔑drei\tvier"
            let representations: [(String, Data)] = [
                ("utf8", Data(original.utf8)),
                ("utf8-bom", Data([0xEF, 0xBB, 0xBF]) + Data(original.utf8)),
                ("utf16-le", Data([0xFF, 0xFE]) + original.data(using: .utf16LittleEndian)!),
                ("utf16-be", Data([0xFE, 0xFF]) + original.data(using: .utf16BigEndian)!)
            ]
            for (name, data) in representations {
                let path = root.appendingPathComponent(name).appendingPathExtension("txt")
                try data.write(to: path)
                try check(try PasswordText.importCandidates(from: path) == ["eins", "zwei", "🔑drei", "vier"], "Wrong candidates for \(name)")
            }
        }

        test("RTF formatting is removed before candidate splitting") {
            let path = root.appendingPathComponent("formatted.rtf")
            let rtf = #"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs24 \b alpha\b0  beta\par \i gamma\i0\tab delta}"#
            try Data(rtf.utf8).write(to: path)
            try check(try PasswordText.importCandidates(from: path) == ["alpha", "beta", "gamma", "delta"], "RTF controls or formatting entered candidate list")
        }

        test("Malformed text is rejected without mutating its file") {
            let path = root.appendingPathComponent("malformed.txt")
            let original = Data([0xC3, 0x28, 0xFF, 0x00])
            try original.write(to: path)
            try expectThrow("Malformed UTF-8 was accepted") { _ = try PasswordText.importCandidates(from: path) }
            try check(try Data(contentsOf: path) == original, "Failed import modified original data")
        }

        test("Stored lines retain leading, trailing and internal manual password spaces") {
            let lines = PasswordText.storedLines(in: "\u{FEFF} leading \r\ninside space\rtrailing \n\n")
            try check(lines == [" leading ", "inside space", "trailing "], "Stored manual passwords were split or trimmed")
        }

        test("Password list survives save, new storage instance and UTF-8 reload") {
            let path = root.appendingPathComponent("saved-passwords.txt")
            let values = [" leading ", "inside space", "🔑Pass!", "tail "]
            let writer = PasswordListStorage(defaults: defaults)
            try writer.save(values, to: path)
            writer.remember(path)
            let reader = PasswordListStorage(defaults: UserDefaults(suiteName: suiteName)!)
            try check(reader.rememberedURL?.standardizedFileURL.path == path.standardizedFileURL.path, "Path was not remembered by a new instance")
            try check(try reader.load(from: path) == values, "Passwords changed after reload")
            try check(String(data: Data(contentsOf: path), encoding: .utf8) != nil, "Saved list is not UTF-8")
        }

        test("Remembered path persists across a separate process") {
            let path = root.appendingPathComponent("cross-process.txt")
            let store = PasswordListStorage(defaults: defaults)
            store.remember(path)
            let synchronized = defaults.synchronize()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--read-remembered-path", suiteName, path.standardizedFileURL.path]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            pipe.fileHandleForWriting.closeFile()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            try check(process.terminationStatus == 0, "Remembered location was unavailable to a fresh process (synchronize=\(synchronized)): \(output)")
        }

        test("Persisted list supports duplicate removal and BOM-marked legacy lines") {
            let path = root.appendingPathComponent("existing-list.txt")
            try Data("\u{FEFF}alpha\n alpha \nalpha\nBeta\nBeta\n".utf8).write(to: path)
            let store = PasswordListStorage(defaults: defaults)
            try check(try store.load(from: path) == ["alpha", " alpha ", "Beta"], "Exact stored values/order or duplicate behavior changed")
        }

        test("External changes are preserved until an explicit reload") {
            let path = root.appendingPathComponent("externally-updated.txt")
            let store = PasswordListStorage(defaults: defaults)
            try store.save(["alpha"], to: path)
            _ = try store.load(from: path)
            let external = Data("alpha\nbeta\n".utf8)
            try external.write(to: path, options: .atomic)
            do {
                try store.save(["alpha", "gamma"], to: path)
                throw PasswordCheckFailure(description: "Stale save replaced externally added password")
            } catch PasswordStorageError.externalChange {
                // A stale snapshot must not replace the newer list on disk.
            }
            try check(try Data(contentsOf: path) == external, "Rejected stale save modified the external data")
            let current = try store.load(from: path)
            try check(current == ["alpha", "beta"], "Reload missed external addition")
            try store.save(current + ["gamma"], to: path)
            try check(try store.load(from: path) == ["alpha", "beta", "gamma"], "Save after reload did not retain all entries")
        }

        test("Canonically equivalent Unicode passwords remain distinct UTF-8 values") {
            let path = root.appendingPathComponent("unicode-distinct.txt")
            let values = ["caf\u{00E9}", "cafe\u{0301}"]
            let store = PasswordListStorage(defaults: defaults)
            try store.save(values, to: path)
            let restored = try store.load(from: path)
            try check(restored.map { Data($0.utf8) } == values.map { Data($0.utf8) }, "Unicode normalization or deduplication merged distinct password bytes")
        }

        test("Clearing and saving produces a reloadable empty list") {
            let path = root.appendingPathComponent("cleared.txt")
            let store = PasswordListStorage(defaults: defaults)
            try store.save(["old"], to: path)
            try store.save([], to: path)
            try check(try store.load(from: path).isEmpty, "Saved empty list restored old data")
        }

        test("Missing volume parent is never created by a failed save") {
            let missing = root.appendingPathComponent("Disconnected Volume", isDirectory: true)
            let path = missing.appendingPathComponent("passwords.txt")
            let store = PasswordListStorage(defaults: defaults)
            try expectThrow("Save unexpectedly created the missing volume path") { try store.save(["alpha"], to: path) }
            try check(!fm.fileExists(atPath: missing.path), "Missing volume directory was created")
        }

        test("Failed stored-list read preserves data and remembered location") {
            let good = root.appendingPathComponent("good.txt")
            let broken = root.appendingPathComponent("broken.txt")
            let store = PasswordListStorage(defaults: defaults)
            try store.save(["unchanged"], to: good)
            store.remember(good)
            let brokenData = Data([0xC3, 0x28, 0xFF])
            try brokenData.write(to: broken)
            try expectThrow("Invalid saved list was accepted") { _ = try store.load(from: broken) }
            try check(try store.load(from: good) == ["unchanged"], "Existing valid list was modified")
            try check(try Data(contentsOf: broken) == brokenData, "Broken file was overwritten")
            try check(store.rememberedURL?.standardizedFileURL.path == good.standardizedFileURL.path, "Failed read silently changed selected path")
        }

        test("Fresh saved list is private to its owner") {
            let path = root.appendingPathComponent("owner-only.txt")
            let store = PasswordListStorage(defaults: defaults)
            try store.save(["alpha"], to: path)
            let attrs = try fm.attributesOfItem(atPath: path.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try check(mode & 0o077 == 0 && mode & 0o600 == 0o600, "New file grants group/other access or is not owner-readable/writable")
        }

        lines.append("RESULT \(failures) failed; \(lines.count - failures) passed")
        print(lines.last!)
        try fm.createDirectory(atPath: "Reports", withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: "Reports/password-tests.txt", atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
