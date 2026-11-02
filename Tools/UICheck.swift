import AppKit
import SwiftUI
import Darwin

@main
struct UICheck {
    static var window: NSWindow!
    static var root: URL!
    static var started: Date!
    static var model: BatchModel!
    static var preferences: UserDefaults!
    static var suite: String!
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        do {
            root = URL(fileURLWithPath: "/private/tmp/ArchivBatch-UI-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("Verified payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
            let enc = root.appendingPathComponent("Beispiel A.7z")
            let plain = root.appendingPathComponent("Beispiel B.zip")
            let unmatched = root.appendingPathComponent("Kein Treffer.7z")
            let bad = root.appendingPathComponent("Fehler.rar")
            let tail = root.appendingPathComponent("Danach weiter.zip")
            for (url, password) in [(enc," richtig "),(plain,""),(unmatched,"nicht in liste"),(tail,"")] {
                let p = Process()
                p.executableURL = Bundle.main.url(forResource: "7zz", withExtension: nil)!
                p.arguments = ["a", url.path, source.appendingPathComponent("payload.txt").path, "-y"] + (password.isEmpty ? [] : ["-p" + password])
                p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
            }
            try Data("Not an archive".utf8).write(to: bad)
            suite = "local.archivbatch.ui-check-" + UUID().uuidString
            preferences = UserDefaults(suiteName: suite)!
            model = BatchModel(passwordStorage: PasswordListStorage(defaults: preferences))
            let storeDirectory = root.appendingPathComponent("Passwort-Volume")
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: false)
            let listFile = storeDirectory.appendingPathComponent("Passwoerter.txt")
            try model.usePasswordList(at: listFile)
            let candidateCount = model.addPasswordLines("\u{FEFF}falsch\r\n richtig \r\n richtig \n\nUnicode 🔑")
            precondition(candidateCount == 3 && model.passwords[1].value == " richtig ")
            let input = root.appendingPathComponent("Import.txt")
            try Data("alpha   beta\tgamma\n\nalpha".utf8).write(to: input)
            let imported = try model.importPasswordFile(input)
            precondition(imported == 3 && model.passwords.suffix(3).map(\.value) == ["alpha", "beta", "gamma"])
            let fresh = BatchModel(passwordStorage: PasswordListStorage(defaults: preferences))
            precondition(fresh.passwordListURL?.lastPathComponent == "Passwoerter.txt")
            try fresh.restorePasswordList()
            precondition(fresh.passwords.map(\.value) == model.passwords.map(\.value))
            fresh.removePassword(fresh.passwords.last!.id)
            let afterRemove = try PasswordListStorage(defaults: preferences).load(from: listFile)
            precondition(afterRemove.count == 5)
            try model.restorePasswordList()
            model.passwords.removeAll()
            let afterClear = try PasswordListStorage(defaults: preferences).load(from: listFile)
            precondition(afterClear.isEmpty)
            model.addPasswordLines("\u{FEFF}falsch\r\n richtig \r\n\nUnicode 🔑")
            let disconnected = root.appendingPathComponent("Volume-offline")
            try FileManager.default.moveItem(at: storeDirectory, to: disconnected)
            model.addPasswordLines("voruebergehend")
            precondition(model.passwordStorageFailed && model.hasUnsavedPasswords && model.passwords.count == 4)
            try FileManager.default.moveItem(at: disconnected, to: storeDirectory)
            model.retryPasswordStorage()
            precondition(!model.passwordStorageFailed && !model.hasUnsavedPasswords)
            model.removePassword(model.passwords.last!.id)
            print("PASS UI persistence: automatic add/import/remove/clear, remembered path, restart load, offline volume and retry.")
            let collector = DropCollector(count: 2)
            precondition(collector.receive(plain, index: 1) == nil)
            precondition(collector.receive(enc, index: 0) == [enc,plain])
            model.destination = root.appendingPathComponent("Output")
            model.addArchives([enc,plain,unmatched,bad,tail,enc])
            precondition(model.archives.count == 5)
            model.archives[0].destination = root.appendingPathComponent("Custom Output")
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1050, height: 670), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "ArchivBatch – Oberfläche prüfen"
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            started = Date()
            model.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
            app.run()
        } catch { print("UI CHECK FAILED: \(error)"); exit(1) }
    }
    static func poll() {
        let model = self.model!
        if model.running {
            if Date().timeIntervalSince(started) > 45 { print("UI CHECK TIMEOUT"); model.stop(); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            return
        }
        let states = model.archives.map(\.state)
        guard states == [.done,.done,.unmatched,.failed,.done], model.passwords[1].successes == 1,
              model.archives[0].output?.deletingLastPathComponent().lastPathComponent == "Custom Output" else {
            print("UI CHECK FAILED states: \(states), detail: \(model.archives.map(\.detail))"); exit(1)
        }
        print("PASS UI model: ordered batch, continuation, custom target, password whitespace/BOM/duplicates, Finder URL order.")
        // Public screenshots use sample locations and concise example result text.
        model.passwordListURL = URL(fileURLWithPath: "/Volumes/Archive Library/ArchivBatch-Passwords.txt")
        if let failed = model.archives.firstIndex(where: { $0.state == .failed }) {
            model.archives[failed].detail = "Das Archiv ist beschädigt oder das Format wird nicht unterstützt."
        }
        if let unmatched = model.archives.firstIndex(where: { $0.state == .unmatched }) {
            model.archives[unmatched].detail = "Kein passendes Passwort gefunden. Das Archiv kann auch beschädigt sein."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            capture("Reports/ui-completed.png")
            model.running = true
            model.activePasswordID = model.passwords[1].id
            model.activeArchiveID = model.archives[0].id
            model.archives[0].output = nil
            model.archives[0].state = .testing
            model.archives[0].detail = "Passwort 2 von 3"
            model.completed = 0
            model.message = "Batch gestartet."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                capture("Reports/ui-active.png")
                print("PASS UI screenshots saved.")
                preferences.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
                exit(0)
            }
        }
    }
    static func capture(_ path: String) {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("UI capture failed"); exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do { try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)) }
        catch { print("UI capture failed \(error)"); exit(1) }
    }
}
