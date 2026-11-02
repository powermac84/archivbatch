import Foundation
import Darwin

private struct LocalizationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct LocalizationTests {
    static let fm = FileManager.default
    static var lines: [String] = []
    static var failures = 0
    static let preferenceKey = "local.archivbatch.interfaceLanguage"

    static func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw LocalizationCheckFailure(description: reason) }
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            lines.append("PASS  " + name)
        } catch {
            failures += 1
            lines.append("FAIL  " + name + ": " + String(describing: error))
        }
        print(lines.last!)
    }

    static func freshDefaults() -> (String, UserDefaults) {
        let suite = "local.archivbatch.localization-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    static func clear(_ suite: String, _ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suite)
        _ = defaults.synchronize()
    }

    static func placeholders(_ text: String) throws -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var argumentIndex = 1
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            index += 1
            guard index < characters.count else { throw LocalizationCheckFailure(description: "Dangling percent in format: " + text) }
            if characters[index] == "%" { index += 1; continue }
            var digits = ""
            while index < characters.count, characters[index].isNumber {
                digits.append(characters[index]); index += 1
            }
            if !digits.isEmpty {
                guard index < characters.count, characters[index] == "$" else {
                    throw LocalizationCheckFailure(description: "Unsupported format width in: " + text)
                }
                index += 1
            }
            guard index < characters.count, ["@", "d"].contains(String(characters[index])) else {
                throw LocalizationCheckFailure(description: "Unsupported placeholder in: " + text)
            }
            let position = digits.isEmpty ? argumentIndex : (Int(digits) ?? 0)
            guard position > 0 else { throw LocalizationCheckFailure(description: "Invalid argument position in: " + text) }
            result.append("\(position):" + String(characters[index]))
            if digits.isEmpty { argumentIndex += 1 }
            index += 1
        }
        return result.sorted()
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--read-language" {
            let defaults = UserDefaults(suiteName: args[2])!
            let localization = AppLocalization(defaults: defaults,
                catalogDirectory: URL(fileURLWithPath: args[4], isDirectory: true))
            guard localization.language.rawValue == args[3] else {
                print("Child language mismatch: " + localization.language.rawValue)
                exit(2)
            }
            print("Child language persisted: " + localization.language.rawValue)
            return
        }

        let project = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let catalogDirectory = project.appendingPathComponent("Resources/Localization", isDirectory: true)
        let (suite, defaults) = freshDefaults()
        defer { clear(suite, defaults) }
        let localization = AppLocalization(defaults: defaults, catalogDirectory: catalogDirectory)

        test("Fresh preference defaults to English even with German system-language preferences") {
            let (isolatedSuite, isolatedDefaults) = freshDefaults()
            defer { clear(isolatedSuite, isolatedDefaults) }
            isolatedDefaults.set(["de", "fr"], forKey: "AppleLanguages")
            let instance = AppLocalization(defaults: isolatedDefaults, catalogDirectory: catalogDirectory)
            try check(instance.language == .english, "Fresh UI followed system language instead of English")
            try check(instance.text("queue.waiting") == "Waiting to start", "Default message is not English")
            try check(instance.text("controls.start") == "Start", "Default Start action is not English")
        }
        test("Unsupported saved language falls back to English") {
            let (isolatedSuite, isolatedDefaults) = freshDefaults()
            defer { clear(isolatedSuite, isolatedDefaults) }
            isolatedDefaults.set("unsupported-ZZ", forKey: preferenceKey)
            let instance = AppLocalization(defaults: isolatedDefaults, catalogDirectory: catalogDirectory)
            try check(instance.language == .english, "Unsupported language did not fall back")
            try check(instance.text("controls.cancel") == "Cancel", "English fallback text missing")
        }
        test("Selected language is restored in a new localization instance") {
            localization.select(.french)
            let restored = AppLocalization(defaults: defaults, catalogDirectory: catalogDirectory)
            try check(defaults.string(forKey: preferenceKey) == "fr", "Selected code not saved")
            try check(restored.language == .french, "Selected language not restored")
            try check(defaults.stringArray(forKey: "AppleLanguages") == ["fr"], "Native app language preference not saved")
        }
        test("Preview language changes do not overwrite saved choice") {
            localization.select(.french)
            localization.select(.german, persist: false)
            try check(localization.language == .german, "Preview language did not change")
            let restored = AppLocalization(defaults: defaults, catalogDirectory: catalogDirectory)
            try check(restored.language == .french, "Preview overwrote persistent language")
        }
        test("Selected interface language persists across a separate process") {
            localization.select(.spanish)
            try check(defaults.synchronize(), "Isolated preference suite could not be flushed")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
            process.arguments = ["--read-language", suite, "es", catalogDirectory.path]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            pipe.fileHandleForWriting.closeFile()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try check(process.terminationStatus == 0,
                      "Child preference read failed: " + String(decoding: output, as: UTF8.self))
        }
        test("All nine supported languages have complete nonempty catalogs") {
            let expectedCodes: Set<String> = ["en", "de", "fr", "es", "pt-BR", "zh-Hans", "ja", "hi", "ar"]
            try check(Set(AppLanguage.allCases.map(\.rawValue)) == expectedCodes, "Unexpected supported language set")
            try check(Set(localization.catalogs.keys) == expectedCodes, "A language catalog is missing")
            guard let english = localization.catalogs["en"], !english.isEmpty else {
                throw LocalizationCheckFailure(description: "English source catalog is empty")
            }
            for code in expectedCodes.sorted() {
                let catalog = localization.catalogs[code] ?? [:]
                try check(Set(catalog.keys) == Set(english.keys), "Catalog key coverage differs: " + code)
                for (key, value) in catalog {
                    try check(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              "Empty translation: " + code + "/" + key)
                }
            }
        }
        test("Translated formats preserve argument types and counts") {
            let english = localization.catalogs["en"] ?? [:]
            try check(!english.isEmpty, "No source formats available")
            for language in AppLanguage.allCases {
                guard let catalog = localization.catalogs[language.rawValue] else {
                    throw LocalizationCheckFailure(description: "Missing catalog: " + language.rawValue)
                }
                for (key, source) in english {
                    let expected = try placeholders(source)
                    let actual = try placeholders(catalog[key] ?? "")
                    try check(actual == expected, "Placeholder mismatch: " + language.rawValue + "/" + key)
                }
            }
        }
        test("Missing translations safely fall back to the English template") {
            let temporary = project.appendingPathComponent(".build/PartialCatalog-" + UUID().uuidString)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporary) }
            for language in AppLanguage.allCases {
                var catalog = localization.catalogs[language.rawValue] ?? [:]
                if language == .french { catalog.removeValue(forKey: "controls.start") }
                let data = try JSONSerialization.data(withJSONObject: catalog)
                try data.write(to: temporary.appendingPathComponent(language.rawValue + ".json"))
            }
            let partial = AppLocalization(defaults: defaults, catalogDirectory: temporary)
            partial.select(.french, persist: false)
            try check(partial.text("controls.start") == "Start", "Missing translation did not fall back to English")
        }
        test("Keyed existing messages re-render after a language switch") {
            let message = LocalizedMessage(key: "queue.finished", arguments: [3, 2])
            localization.select(.english, persist: false)
            let english = message.rendered(using: localization)
            try check(english == "Batch complete: 3 extracted, 2 unsuccessful.", "English message formatting changed")
            localization.select(.german, persist: false)
            let german = message.rendered(using: localization)
            try check(german != english, "Existing message stayed in the previous language")
            try check(german == localization.text("queue.finished", arguments: [3, 2]), "Existing message did not use current language")
        }
        test("Nested messages use the current language for both layers") {
            let message = M("store.load_failed", M("engine.no_match"))
            for language in [AppLanguage.english, .french, .arabic] {
                localization.select(language, persist: false)
                let nested = localization.text("engine.no_match")
                let expected = localization.text("store.load_failed", arguments: [nested])
                try check(message.rendered(using: localization) == expected,
                          "Nested message language mismatch: " + language.rawValue)
            }
        }
        test("Filename, path, punctuation and password bytes remain verbatim in every language") {
            let literal = "/Volumes/Archive Library/é_e\u{0301}_日本語_🔐_%@_%d_{}_$'\\.zip"
            let literalBytes = Data(literal.utf8)
            for language in AppLanguage.allCases {
                localization.select(language, persist: false)
                let rendered = M("store.saved_file", literal).rendered(using: localization)
                try check(Data(rendered.utf8).range(of: literalBytes) != nil,
                          "Inserted user bytes changed: " + language.rawValue)
                let importResult = localization.text("import.complete", arguments: [7, literal])
                try check(Data(importResult.utf8).range(of: literalBytes) != nil,
                          "Formatted user bytes changed: " + language.rawValue)
            }
        }
        test("Literal text is never interpreted as a translation key") {
            let message: LocalizedMessage = "controls.start"
            for language in AppLanguage.allCases {
                localization.select(language, persist: false)
                try check(message.rendered(using: localization) == "controls.start", "Literal was translated")
            }
        }
        test("Arabic uses right-to-left layout; all other supported languages use left-to-right") {
            for language in AppLanguage.allCases {
                try check(language.isRightToLeft == (language == .arabic), "Incorrect direction: " + language.rawValue)
            }
            let names = AppLanguage.allCases.map(\.nativeName)
            try check(names.allSatisfy { !$0.isEmpty } && Set(names).count == names.count,
                      "Language choices need unique nonempty native names")
        }
        test("The shipped app declares English as its development language") {
            let data = try Data(contentsOf: project.appendingPathComponent("Info.plist"))
            let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            try check(info?["CFBundleDevelopmentRegion"] as? String == "en", "App bundle default remains non-English")
        }

        lines.append("RESULT \(failures) failed; \(lines.filter { $0.hasPrefix("PASS") }.count) passed")
        let report = project.appendingPathComponent("Reports/localization-tests.txt")
        try fm.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        print(lines.last!)
        if failures > 0 { exit(1) }
    }
}
