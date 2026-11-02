import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct EngineIntegrationTests {
    static let fm = FileManager.default
    static var lines: [String] = []
    static var failures = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw CheckFailure(description: reason) }
    }

    @discardableResult
    static func command(_ executable: URL, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        try check(process.terminationStatus == 0, "Fixture process failed (\(process.terminationStatus)): \(text)")
        return text
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

    static func successful(_ outcome: EngineOutcome, contents: Data, index: Int?) throws -> URL {
        guard case .success(let output, let acceptedIndex) = outcome else {
            throw CheckFailure(description: "Expected success; got \(description(outcome))")
        }
        try check(acceptedIndex == index, "Wrong accepted password index: \(String(describing: acceptedIndex))")
        let actual = try Data(contentsOf: output.appendingPathComponent("payload.txt"))
        try check(actual == contents, "Extracted content differs")
        return output
    }

    static func description(_ outcome: EngineOutcome) -> String {
        switch outcome {
        case .success(let path, let index): return "success \(path.lastPathComponent) index \(String(describing: index))"
        case .failure(let reason): return "failure: \(reason)"
        case .noMatch(let reason): return "noMatch: \(reason)"
        case .cancelled: return "cancelled"
        }
    }

    static func duplicatePathZip() -> Data {
        var local = Data()
        var central = Data()
        func append(_ value: UInt32, bytes: Int, to data: inout Data) {
            for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0) }
            }
            return ~crc
        }
        let name = Data("payload.txt".utf8)
        for content in [Data("First stored entry".utf8), Data("Second stored entry".utf8)] {
            let offset = UInt32(local.count)
            let crc = crc32(content)
            append(0x04034B50, bytes: 4, to: &local)
            for value: UInt32 in [20, 0, 0, 0, 0] { append(value, bytes: 2, to: &local) }
            append(crc, bytes: 4, to: &local)
            append(UInt32(content.count), bytes: 4, to: &local)
            append(UInt32(content.count), bytes: 4, to: &local)
            append(UInt32(name.count), bytes: 2, to: &local)
            append(0, bytes: 2, to: &local)
            local.append(name)
            local.append(content)
            append(0x02014B50, bytes: 4, to: &central)
            for value: UInt32 in [20, 20, 0, 0, 0, 0] { append(value, bytes: 2, to: &central) }
            append(crc, bytes: 4, to: &central)
            append(UInt32(content.count), bytes: 4, to: &central)
            append(UInt32(content.count), bytes: 4, to: &central)
            append(UInt32(name.count), bytes: 2, to: &central)
            for _ in 0..<4 { append(0, bytes: 2, to: &central) }
            append(0, bytes: 4, to: &central)
            append(offset, bytes: 4, to: &central)
            central.append(name)
        }
        let offset = UInt32(local.count)
        let size = UInt32(central.count)
        local.append(central)
        append(0x06054B50, bytes: 4, to: &local)
        for value: UInt32 in [0, 0, 2, 2] { append(value, bytes: 2, to: &local) }
        append(size, bytes: 4, to: &local)
        append(offset, bytes: 4, to: &local)
        append(0, bytes: 2, to: &local)
        return local
    }

    static func main() throws {
        let project = URL(fileURLWithPath: fm.currentDirectoryPath)
        let sevenZip = project.appendingPathComponent("Vendor/7zz")
        let workspace = project.appendingPathComponent(".build/EngineFixtures-" + UUID().uuidString, isDirectory: true)
        let inputs = workspace.appendingPathComponent("inputs", isDirectory: true)
        let fixtures = workspace.appendingPathComponent("fixtures", isDirectory: true)
        let output = workspace.appendingPathComponent("output", isDirectory: true)
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let payload = Data("ArchivBatch Integrationstest — äöü 日本語\nOriginalinhalt bleibt erhalten.\n".utf8)
        try payload.write(to: inputs.appendingPathComponent("payload.txt"))

        let headerArchive = fixtures.appendingPathComponent("encrypted-header.7z")
        let aesArchive = fixtures.appendingPathComponent("aes.zip")
        let clearArchive = fixtures.appendingPathComponent("clear.7z")
        let unicodeArchive = fixtures.appendingPathComponent("Unicode und Leerzeichen.7z")
        let unicodePassword = "  größe 🔑  "
        try command(sevenZip, ["a", "-t7z", "-mx1", "-mhe=on", "-pcorrect", headerArchive.path, "payload.txt"], cwd: inputs)
        try command(sevenZip, ["a", "-tzip", "-mx1", "-mem=AES256", "-pzip-secret", aesArchive.path, "payload.txt"], cwd: inputs)
        try command(sevenZip, ["a", "-t7z", "-mx1", clearArchive.path, "payload.txt"], cwd: inputs)
        try command(sevenZip, ["a", "-t7z", "-mx1", "-mhe=on", "-p" + unicodePassword, unicodeArchive.path, "payload.txt"], cwd: inputs)

        func run(_ archive: URL, passwords: [String], root: URL? = nil,
                 attempts: ((Int?) -> Void)? = nil) -> EngineOutcome {
            ArchiveEngine(executable: sevenZip).process(archive: archive, destinationRoot: root ?? output,
                passwords: passwords) { event in
                    if case .attempt(let index) = event { attempts?(index) }
                }
        }

        test("7z encrypted headers; wrong then right; ordered attempts") {
            var attempted: [Int?] = []
            _ = try successful(run(headerArchive, passwords: ["wrong", "correct", "unused"], attempts: { attempted.append($0) }),
                               contents: payload, index: 1)
            try check(attempted.count == 3 && attempted[0] == nil && attempted[1] == 0 && attempted[2] == 1,
                      "Unexpected candidate order: \(attempted)")
        }
        test("AES-256 ZIP; byte-exact extracted content") {
            _ = try successful(run(aesArchive, passwords: ["wrong", "zip-secret"]), contents: payload, index: 1)
        }
        test("Encrypted archive filename may contain diagnostic words") {
            let archive = fixtures.appendingPathComponent("no space left.7z")
            try fm.copyItem(at: headerArchive, to: archive)
            _ = try successful(run(archive, passwords: ["wrong", "correct"]), contents: payload, index: 1)
        }
        test("Unicode password preserves leading and trailing spaces") {
            _ = try successful(run(unicodeArchive, passwords: [unicodePassword.trimmingCharacters(in: .whitespaces), unicodePassword]),
                               contents: payload, index: 1)
        }
        test("Unencrypted archive succeeds with empty candidate list") {
            _ = try successful(run(clearArchive, passwords: []), contents: payload, index: nil)
        }
        test("Wrong candidates marked noMatch and leave no output") {
            let destination = workspace.appendingPathComponent("wrong-output")
            let result = run(headerArchive, passwords: ["wrong-a", "wrong-b"], root: destination)
            guard case .noMatch(let message) = result else { throw CheckFailure(description: description(result)) }
            try check(!message.contains("wrong-a") && !message.contains("wrong-b"), "Diagnostic leaks candidate values")
            try check(!fm.fileExists(atPath: destination.path), "Wrong password created output")
        }
        test("Malformed archive marked failure and leaves no output") {
            for extensionName in ["7z", "rar"] {
                let archive = fixtures.appendingPathComponent("malformed." + extensionName)
                try Data("This is not an archive.".utf8).write(to: archive)
                let destination = workspace.appendingPathComponent("malformed-output-" + extensionName)
                let result = run(archive, passwords: ["correct"], root: destination)
                guard case .failure = result else { throw CheckFailure(description: description(result)) }
                try check(!fm.fileExists(atPath: destination.path), "Malformed archive created output")
            }
        }
        test("Existing output untouched; collision gets distinct directory") {
            let existing = output.appendingPathComponent("clear")
            let sentinel = existing.appendingPathComponent("sentinel.txt")
            try Data("DO NOT CHANGE".utf8).write(to: sentinel)
            let result = try successful(run(clearArchive, passwords: []), contents: payload, index: nil)
            try check(result.lastPathComponent == "clear (2)", "Collision did not create expected distinct folder")
            try check(try Data(contentsOf: sentinel) == Data("DO NOT CHANGE".utf8), "Existing file was modified")
            try check(try Data(contentsOf: existing.appendingPathComponent("payload.txt")) == payload, "Existing extraction was changed")
        }
        test("Per-archive destination override") {
            let override = workspace.appendingPathComponent("custom destination")
            let extracted = try successful(run(aesArchive, passwords: ["zip-secret"], root: override), contents: payload, index: 0)
            try check(extracted.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                .path == override.standardizedFileURL.resolvingSymlinksInPath().path,
                      "Extraction ignored destination override")
        }
        if fm.isExecutableFile(atPath: "/usr/bin/zip") {
            test("Legacy ZipCrypto from system zip") {
                let archive = fixtures.appendingPathComponent("legacy.zip")
                try command(URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-P", "legacy-secret", archive.path, "payload.txt"], cwd: inputs)
                _ = try successful(run(archive, passwords: ["wrong", "legacy-secret"]), contents: payload, index: 1)
            }
        } else { lines.append("SKIP  Legacy ZIP: /usr/bin/zip unavailable") }

        for version in [4, 5] {
            test("RAR\(version) encrypted filenames; four extracted contents") {
                let archive = project.appendingPathComponent("Tests/rar\(version)-encrypted-filenames.rar")
                let result = run(archive, passwords: ["wrong", "password"])
                guard case .success(let extracted, let index) = result else {
                    throw CheckFailure(description: description(result))
                }
                try check(index == 1, "RAR accepted wrong password index")
                for filename in ["a.txt", "b.txt", "c.txt", "d.txt"] {
                    let content = try Data(contentsOf: extracted.appendingPathComponent(filename))
                    try check(content == Data("This is from \(filename)".utf8), "RAR entry differs: \(filename)")
                }
            }
        }

        test("Archive containing symbolic link rejected") {
            let linkInputs = workspace.appendingPathComponent("link-inputs")
            try fm.createDirectory(at: linkInputs, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: linkInputs.appendingPathComponent("link").path,
                                      withDestinationPath: "../inputs/payload.txt")
            let archive = fixtures.appendingPathComponent("with-link.7z")
            try command(sevenZip, ["a", "-t7z", "-snl", archive.path, "link"], cwd: linkInputs)
            let destination = workspace.appendingPathComponent("link-output")
            let result = run(archive, passwords: [], root: destination)
            guard case .failure = result else { throw CheckFailure(description: description(result)) }
            try check(!fm.fileExists(atPath: destination.path), "Link archive was extracted")
        }
        test("Duplicate ZIP paths preserve both file contents") {
            let archive = fixtures.appendingPathComponent("duplicate.zip")
            try duplicatePathZip().write(to: archive)
            try command(sevenZip, ["t", archive.path])
            let result = run(archive, passwords: [])
            guard case .success(let extracted, _) = result else { throw CheckFailure(description: description(result)) }
            let files = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }.sorted()
            try check(contents == ["First stored entry", "Second stored entry"], "Duplicate path silently lost an entry: \(contents)")
        }

        test("Failed extraction removes restrictive staging; external symlink stays untouched") {
            let destination = workspace.appendingPathComponent("locked-output")
            let external = workspace.appendingPathComponent("external-held")
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            let marker = external.appendingPathComponent("preserve.txt")
            try Data("PRESERVE EXTERNAL".utf8).write(to: marker)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: external.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: external.path) }
            let wrapper = workspace.appendingPathComponent("restrict-staging.sh")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = """
            #!/bin/bash
            if [ "$1" != x ]; then exec \(quote(sevenZip.path)) "$@"; fi
            \(quote(sevenZip.path)) "$@" || exit "$?"
            output_directory=''
            for arg in "$@"; do
                case "$arg" in -o*) output_directory="${arg#-o}" ;; esac
            done
            [ -n "$output_directory" ] || exit 7
            mkdir -p "$output_directory/restricted/nested"
            printf '%s' locked > "$output_directory/restricted/nested/locked.txt"
            ln -s \(quote(external.path)) "$output_directory/external-link"
            chmod 000 "$output_directory/restricted/nested" "$output_directory/restricted"
            printf '%s\\n' 'ERROR: forced extraction failure for cleanup verification'
            exit 2
            """
            try Data(script.utf8).write(to: wrapper)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let result = ArchiveEngine(executable: wrapper).process(archive: clearArchive,
                destinationRoot: destination, passwords: []) { _ in }
            guard case .failure = result else { throw CheckFailure(description: description(result)) }
            let remaining = try fm.contentsOfDirectory(atPath: destination.path)
            try check(remaining.isEmpty, "Restricted staging folder was left behind: \(remaining)")
            try check(try Data(contentsOf: marker) == Data("PRESERVE EXTERNAL".utf8), "External linked content changed")
            let mode = try fm.attributesOfItem(atPath: external.path)[.posixPermissions] as? NSNumber
            try check(mode?.intValue == 0o500, "Cleanup changed external directory permissions")
        }

        test("Cancel active 7zz; cleanup; subsequent new engine succeeds") {
            let largeInputs = workspace.appendingPathComponent("large-inputs")
            try fm.createDirectory(at: largeInputs, withIntermediateDirectories: true)
            let largeFile = largeInputs.appendingPathComponent("large.bin")
            try Data(repeating: 0x5A, count: 64 * 1024 * 1024).write(to: largeFile)
            let largeArchive = fixtures.appendingPathComponent("cancel.7z")
            try command(sevenZip, ["a", "-t7z", "-mx0", "-mhe=on", "-pcancel-secret", largeArchive.path, "large.bin"], cwd: largeInputs)
            let pidFile = workspace.appendingPathComponent("active.pid")
            let wrapper = workspace.appendingPathComponent("record-process.sh")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "#!/bin/bash\nprintf '%s\\n' \"$$\" > " + quote(pidFile.path) + "\nexec " + quote(sevenZip.path) + " \"$@\"\n"
            try Data(script.utf8).write(to: wrapper)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let engine = ArchiveEngine(executable: wrapper)
            let cancellationObserved = DispatchSemaphore(value: 0)
            let cancelledDuringProcess = NSLock()
            var liveProcessConfirmed = false
            let destination = workspace.appendingPathComponent("cancel-output")
            let started = Date()
            let result = engine.process(archive: largeArchive, destinationRoot: destination, passwords: ["cancel-secret"]) { event in
                if case .attempt(let index) = event, index == 0 {
                    try? fm.removeItem(at: pidFile)
                    DispatchQueue.global().async {
                        let deadline = Date().addingTimeInterval(3)
                        while Date() < deadline {
                            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                // The wrapper keeps its PID across exec. Wait for the actual
                                // 7zz image instead of assuming a fixed delay is long enough.
                                var pathBuffer = [CChar](repeating: 0, count: 4096)
                                let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
                                let image = pathLength > 0 ? String(cString: pathBuffer) : ""
                                if URL(fileURLWithPath: image).lastPathComponent == sevenZip.lastPathComponent,
                                   Darwin.kill(pid, SIGSTOP) == 0 {
                                    // Freeze the confirmed child before requesting cancellation:
                                    // a fast machine must not finish between the assertion and cancel().
                                    defer { _ = Darwin.kill(pid, SIGCONT) }
                                    var stoppedPath = [CChar](repeating: 0, count: 4096)
                                    let stoppedLength = proc_pidpath(pid, &stoppedPath, UInt32(stoppedPath.count))
                                    if stoppedLength > 0,
                                       String(cString: stoppedPath) == image,
                                       Darwin.kill(pid, 0) == 0 {
                                        cancelledDuringProcess.lock()
                                        liveProcessConfirmed = true
                                        cancelledDuringProcess.unlock()
                                        engine.cancel()
                                        cancellationObserved.signal()
                                        return
                                    }
                                }
                            }
                            Thread.sleep(forTimeInterval: 0.0002)
                        }
                        engine.cancel()
                        cancellationObserved.signal()
                    }
                }
            }
            _ = cancellationObserved.wait(timeout: .now() + 4)
            guard case .cancelled = result else { throw CheckFailure(description: description(result)) }
            cancelledDuringProcess.lock()
            let confirmed = liveProcessConfirmed
            cancelledDuringProcess.unlock()
            try check(confirmed, "Cancellation was not observed while subprocess was alive")
            try check(Date().timeIntervalSince(started) < 5, "Stop latency exceeded 5 seconds")
            if fm.fileExists(atPath: destination.path) {
                let entries = try fm.contentsOfDirectory(atPath: destination.path)
                try check(entries.isEmpty, "Cancellation left output or staging data")
            }
            _ = try successful(run(clearArchive, passwords: []), contents: payload, index: nil)
        }

        lines.append("RAR fixtures: official libarchive regression fixtures; encrypted filenames in both RAR4 and RAR5.")
        lines.append("RESULT \(failures) failed; \(lines.filter { $0.hasPrefix("PASS") }.count) passed")
        let report = project.appendingPathComponent("Reports/engine-tests.txt")
        try fm.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        print(lines.last!)
        if failures > 0 { exit(1) }
    }
}
