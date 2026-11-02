import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PasswordItem: Identifiable {
    let id = UUID()
    let value: String
    var successes = 0
}

enum ArchiveState: String {
    case queued = "Bereit", testing = "Prüft", extracting = "Entpacken", done = "Fertig"
    case unmatched = "Kein Treffer", failed = "Fehler", cancelled = "Gestoppt"
    var color: Color {
        switch self {
        case .done: return .green
        case .unmatched: return .orange
        case .failed: return .red
        case .testing, .extracting: return .accentColor
        default: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .unmatched, .failed: return "exclamationmark.circle.fill"
        case .testing, .extracting: return "arrow.triangle.2.circlepath"
        case .cancelled: return "stop.circle"
        case .queued: return "archivebox"
        }
    }
}

struct ArchiveItem: Identifiable {
    let id = UUID()
    let url: URL
    var destination: URL?
    var state: ArchiveState = .queued
    var detail = "Wartet auf Start"
    var output: URL?
    var matchedPassword: String?
}

final class BatchModel: ObservableObject {
    static let shared = BatchModel()
    @Published var archives: [ArchiveItem] = []
    @Published var passwords: [PasswordItem] = [] {
        didSet {
            if oldValue.map({ Data($0.value.utf8) }) != passwords.map({ Data($0.value.utf8) }), !suppressPasswordSave {
                persistPasswordList()
            }
        }
    }
    @Published var passwordListURL: URL?
    @Published var passwordStorageMessage = "Noch kein Speicherort gewählt"
    @Published var passwordStorageFailed = false
    private(set) var hasUnsavedPasswords = false
    @Published var passwordInput = ""
    @Published var dropTargeted = false
    @Published var destination: URL?
    @Published var running = false
    @Published var stopping = false
    @Published var activePasswordID: UUID?
    @Published var activeArchiveID: UUID?
    @Published var completed = 0
    @Published var total = 0
    @Published var message = "Archive ablegen und mögliche Passwörter hinzufügen."
    @Published var alertMessage: String?
    private let passwordStorage: PasswordListStorage
    private var passwordFileLoaded = false
    private var passwordFileNeedsReload = false
    private var suppressPasswordSave = false
    private var engine: ArchiveEngine?
    private var askedForDestination = false
    private let worker = DispatchQueue(label: "de.archivbatch.worker", qos: .userInitiated)

    init(passwordStorage: PasswordListStorage = PasswordListStorage()) {
        self.passwordStorage = passwordStorage
        self.passwordListURL = passwordStorage.rememberedURL
        if passwordListURL != nil { passwordStorageMessage = "Noch nicht geladen" }
    }

    var canStart: Bool { !running && destination != nil && archives.contains { $0.state != .done } }

    func chooseInitialDestination() {
        guard !askedForDestination else { return }
        askedForDestination = true
        choosePasswordLocationAtStartup()
        chooseDestination()
    }

    func chooseDestination(for id: UUID? = nil) {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = id == nil ? "Zielordner für die Archive wählen" : "Eigenen Zielordner wählen"
        panel.message = "Jedes Archiv wird in einen eigenen Unterordner entpackt."
        panel.prompt = "Ziel wählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let id, let index = archives.firstIndex(where: { $0.id == id }) {
            archives[index].destination = url
        } else {
            destination = url
        }
    }

    func addFromPanel() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = "Archive hinzufügen"
        panel.prompt = "Hinzufügen"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addArchives(panel.urls) }
    }

    private func firstVolume(_ url: URL) -> URL {
        let name = url.lastPathComponent
        let patterns = ["(?i)^(.*\\.part)([0-9]+)(\\.rar)$", "(?i)^(.*\\.(?:7z|zip)\\.)([0-9]{3})()$"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
               let a = Range(match.range(at: 1), in: name),
               let b = Range(match.range(at: 2), in: name),
               let c = Range(match.range(at: 3), in: name),
               let number = Int(name[b]), number > 1 {
                let replacement = String(name[a]) + String(repeating: "0", count: name[b].count - 1) + "1" + String(name[c])
                let first = url.deletingLastPathComponent().appendingPathComponent(replacement)
                if FileManager.default.fileExists(atPath: first.path) { return first }
            }
        }
        if name.range(of: "(?i)\\.r[0-9]{2}$", options: .regularExpression) != nil {
            let first = url.deletingPathExtension().appendingPathExtension("rar")
            if FileManager.default.fileExists(atPath: first.path) { return first }
        }
        return url
    }

    func addArchives(_ urls: [URL]) {
        guard !running else { return }
        var added = 0
        var rejected = 0
        for original in urls {
            guard original.isFileURL else { rejected += 1; continue }
            let url = firstVolume(original).standardizedFileURL.resolvingSymlinksInPath()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { rejected += 1; continue }
            guard !archives.contains(where: { $0.url == url }) else { continue }
            archives.append(ArchiveItem(url: url))
            added += 1
        }
        message = "\(added) Archiv\(added == 1 ? "" : "e") hinzugefügt."
        if rejected > 0 { message += " \(rejected) Ordner oder ungültige Dateien ausgelassen." }
    }

    private func choosePasswordLocationAtStartup() {
        guard let url = passwordListURL else { choosePasswordLocation(); return }
        do { try restorePasswordList() }
        catch {
            passwordStorageFailed = true
            passwordStorageMessage = "Nicht geladen: " + error.localizedDescription
        }
        let alert = NSAlert()
        alert.messageText = "Speicherort der Passwortliste"
        alert.informativeText = url.path + "\n\n" + (passwordFileLoaded
            ? "\(passwords.count) Passwörter geladen. Änderungen werden hier automatisch gespeichert."
            : "Die Liste konnte nicht geladen werden. Verbinde das Volume oder wähle einen anderen Speicherort.\n" + passwordStorageMessage)
        alert.addButton(withTitle: passwordFileLoaded ? "Verwenden" : "Erneut laden")
        alert.addButton(withTitle: "Speicherort ändern …")
        alert.addButton(withTitle: "Später")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { choosePasswordLocation() }
        else if response == .alertFirstButtonReturn, !passwordFileLoaded { retryPasswordStorage() }
    }

    func choosePasswordLocation() {
        guard !running else { return }
        let panel = NSSavePanel()
        panel.title = "Passwortliste speichern"
        panel.message = "Wähle eine Textdatei auf dem gewünschten Volume. Aktuelle und dort bereits vorhandene Passwörter werden zusammengeführt. Die Liste wird als Klartext gespeichert."
        panel.prompt = "Verwenden"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = passwordListURL?.lastPathComponent ?? "ArchivBatch-Passwoerter.txt"
        if let url = passwordListURL, FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try usePasswordList(at: url) }
        catch { alertMessage = "Die Passwortliste konnte an diesem Ort nicht verwendet werden: " + error.localizedDescription }
    }

    /// Switching stores is transactional: read and save the merged list before adopting the path.
    func usePasswordList(at url: URL) throws {
        let isCurrent = passwordFileLoaded && url.standardizedFileURL == passwordListURL?.standardizedFileURL
        let existing = !isCurrent && FileManager.default.fileExists(atPath: url.path) ? try passwordStorage.load(from: url) : []
        let values = uniquePasswords(existing + passwords.map(\.value))
        try passwordStorage.save(values, to: url)
        passwordStorage.remember(url)
        passwordListURL = url
        passwordFileLoaded = true
        passwordFileNeedsReload = false
        replacePasswordValues(values)
        passwordStorageFailed = false
        hasUnsavedPasswords = false
        passwordStorageMessage = "Automatisch gespeichert · \(passwords.count) Passwörter"
        message = "Passwortliste gespeichert: " + url.lastPathComponent
    }

    func restorePasswordList() throws {
        guard let url = passwordListURL else { return }
        let values = try passwordStorage.load(from: url)
        // Keep entries added while the saved volume was not available.
        replacePasswordValues(uniquePasswords(values + passwords.map(\.value)))
        passwordFileLoaded = true
        passwordFileNeedsReload = false
        passwordStorageFailed = false
        hasUnsavedPasswords = values.map { Data($0.utf8) } != passwords.map { Data($0.value.utf8) }
        passwordStorageMessage = "Geladen · \(passwords.count) Passwörter"
        if values.map { Data($0.utf8) } != passwords.map { Data($0.value.utf8) } { persistPasswordList() }
    }

    private func replacePasswordValues(_ values: [String]) {
        let previous = Dictionary(passwords.map { (Data($0.value.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        suppressPasswordSave = true
        passwords = values.map { previous[Data($0.utf8)] ?? PasswordItem(value: $0) }
        suppressPasswordSave = false
    }

    private func uniquePasswords(_ values: [String]) -> [String] {
        var seen = Set<Data>()
        return values.filter { !$0.isEmpty && seen.insert(Data($0.utf8)).inserted }
    }

    func persistPasswordList() {
        hasUnsavedPasswords = true
        guard let url = passwordListURL else {
            passwordStorageMessage = "Noch nicht gespeichert – Speicherort wählen"
            return
        }
        guard passwordFileLoaded else {
            passwordStorageFailed = true
            passwordStorageMessage = "Nicht gespeichert – gespeicherte Liste zuerst laden"
            return
        }
        do {
            try passwordStorage.save(passwords.map(\.value), to: url)
            passwordStorageFailed = false
            hasUnsavedPasswords = false
            passwordStorageMessage = "Automatisch gespeichert · \(passwords.count) Passwörter"
        } catch {
            passwordStorageFailed = true
            if case PasswordStorageError.externalChange = error { passwordFileNeedsReload = true }
            passwordStorageMessage = "Nicht gespeichert: " + error.localizedDescription
        }
    }

    func retryPasswordStorage() {
        guard !running else { return }
        if passwordFileLoaded && !passwordFileNeedsReload { persistPasswordList() }
        else {
            do { try restorePasswordList() }
            catch {
                passwordStorageFailed = true
                passwordStorageMessage = "Nicht geladen: " + error.localizedDescription
            }
        }
    }

    func addPassword() {
        guard !running else { return }
        let value = passwordInput
        passwordInput = ""
        let count = addPasswordLines(value)
        if count > 0 { message = "\(count) Passwort\(count == 1 ? "" : "er") hinzugefügt." }
    }

    @discardableResult
    func addPasswordValues(_ values: [String]) -> Int {
        guard !running else { return 0 }
        var items = passwords
        var seen = Set(items.map { Data($0.value.utf8) })
        for value in values where !value.isEmpty {
            if seen.insert(Data(value.utf8)).inserted { items.append(PasswordItem(value: value)) }
        }
        let count = items.count - passwords.count
        if count > 0 { passwords = items }
        return count
    }

    @discardableResult
    func addPasswordLines(_ text: String) -> Int {
        addPasswordValues(PasswordText.storedLines(in: text))
    }

    @discardableResult
    func importPasswordFile(_ url: URL) throws -> Int {
        let count = addPasswordValues(try PasswordText.importCandidates(from: url))
        message = "\(count) neue Passwörter aus \(url.lastPathComponent) eingelesen. Duplikate ausgelassen."
        return count
    }

    func importPasswords() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = "Passwörter aus Text importieren"
        panel.message = "Jede durch Leerzeichen, Tabulatoren oder Absätze getrennte Zeichenfolge wird ein Passwort. Formatierungen werden ignoriert."
        panel.prompt = "Einlesen"
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importPasswordFile(url) }
        catch { alertMessage = "Die Textdatei konnte nicht gelesen werden: \(error.localizedDescription)" }
    }

    func removeArchive(_ id: UUID) { if !running { archives.removeAll { $0.id == id } } }
    func removePassword(_ id: UUID) { if !running { passwords.removeAll { $0.id == id } } }
    func resetDestination(_ id: UUID) {
        if !running, let index = archives.firstIndex(where: { $0.id == id }) { archives[index].destination = nil }
    }
    func clearFinished() { if !running { archives.removeAll { $0.state == .done } } }

    func start() {
        guard canStart, let destination else { return }
        if !passwordInput.isEmpty { addPassword() }
        guard let executable = Bundle.main.url(forResource: "7zz", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            alertMessage = "Der mitgelieferte Entpacker fehlt. Bitte die App neu erstellen."
            return
        }
        let candidates = passwords
        let pending = archives.filter { $0.state != .done }
        for index in archives.indices where archives[index].state != .done {
            archives[index].state = .queued
            archives[index].detail = "Wartet auf Start"
            archives[index].output = nil
            archives[index].matchedPassword = nil
        }
        let engine = ArchiveEngine(executable: executable)
        self.engine = engine
        completed = 0
        total = pending.count
        running = true
        stopping = false
        message = "Batch gestartet."
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Archive werden entpackt")
        worker.async { [weak self] in
            guard let self else { return }
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Archive entpacken")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for item in pending {
                var shouldStop = false
                DispatchQueue.main.sync {
                    shouldStop = self.stopping
                    if !shouldStop {
                        self.activeArchiveID = item.id
                        self.update(item.id, state: .testing, detail: "Ohne Passwort prüfen …")
                    }
                }
                if shouldStop { break }
                let outcome = engine.process(archive: item.url, destinationRoot: item.destination ?? destination,
                                             passwords: candidates.map(\.value)) { event in
                    DispatchQueue.main.sync {
                        switch event {
                        case .attempt(let index):
                            self.activePasswordID = index.map { candidates[$0].id }
                            let detail = index.map { "Passwort \($0 + 1) von \(candidates.count)" } ?? "Ohne Passwort prüfen …"
                            self.update(item.id, state: .testing, detail: detail)
                        case .progress(let text):
                            let state: ArchiveState = text.hasPrefix("Prüfe Passwort") || text.hasPrefix("Prüfe Archiv") ? .testing : .extracting
                            self.update(item.id, state: state, detail: text)
                        }
                    }
                }
                DispatchQueue.main.sync {
                    self.activePasswordID = nil
                    guard let index = self.archives.firstIndex(where: { $0.id == item.id }) else { return }
                    switch outcome {
                    case .success(let url, let match):
                        self.archives[index].state = .done
                        self.archives[index].detail = match.map { "Entpackt mit Passwort \($0 + 1)" } ?? "Entpackt ohne Passwort"
                        self.archives[index].output = url
                        if let match {
                            self.archives[index].matchedPassword = candidates[match].value
                            if let passwordIndex = self.passwords.firstIndex(where: { $0.id == candidates[match].id }) {
                                self.passwords[passwordIndex].successes += 1
                            }
                        }
                        self.completed += 1
                    case .noMatch(let detail):
                        self.archives[index].state = .unmatched
                        self.archives[index].detail = detail
                        self.completed += 1
                    case .failure(let detail):
                        self.archives[index].state = .failed
                        self.archives[index].detail = detail
                        self.completed += 1
                    case .cancelled:
                        self.archives[index].state = .cancelled
                        self.archives[index].detail = "Verarbeitung gestoppt"
                        self.stopping = true
                    }
                }
            }
            DispatchQueue.main.async {
                for index in self.archives.indices where self.stopping && self.archives[index].state == .queued {
                    self.archives[index].state = .cancelled
                    self.archives[index].detail = "Noch nicht verarbeitet"
                }
                let finished = self.archives.filter { $0.state == .done }.count
                let unsuccessful = self.archives.filter { $0.state == .unmatched || $0.state == .failed }.count
                self.message = self.stopping ? "Gestoppt. Mit Start kannst du fortsetzen." : "Batch fertig: \(finished) entpackt, \(unsuccessful) ohne Erfolg."
                self.activeArchiveID = nil
                self.activePasswordID = nil
                self.running = false
                self.stopping = false
                self.engine = nil
                ProcessInfo.processInfo.enableSuddenTermination()
                ProcessInfo.processInfo.enableAutomaticTermination("Archive werden entpackt")
            }
        }
    }

    private func update(_ id: UUID, state: ArchiveState, detail: String) {
        if let index = archives.firstIndex(where: { $0.id == id }) {
            archives[index].state = state
            archives[index].detail = detail
        }
    }

    func stop() {
        guard running else { return }
        stopping = true
        message = "Wird gestoppt …"
        engine?.cancel()
    }
}

struct ContentView: View {
    @ObservedObject var model = BatchModel.shared
    @FocusState private var passwordFocused: Bool
    private var alertPresented: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                archivePane
                Divider()
                passwordPane.frame(width: 310)
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 610)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("ArchivBatch", isPresented: alertPresented) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.chooseInitialDestination() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox.fill").font(.system(size: 28)).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("ArchivBatch").font(.system(size: 24, weight: .semibold))
                Text("Archive öffnen. Passwörter durchprobieren. Automatisch entpacken.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 4) {
                Text("STANDARDZIEL").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(model.destination?.lastPathComponent ?? "Noch kein Ziel gewählt")
                        .lineLimit(1).help(model.destination?.path ?? "Zielordner wählen")
                    Button("Ändern …") { model.chooseDestination() }.disabled(model.running)
                }
            }.frame(maxWidth: 300)
        }.padding(20)
    }

    private var archivePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archive").font(.headline)
                Text("\(model.archives.count)").foregroundColor(.secondary)
                Spacer()
                Button { model.addFromPanel() } label: { Label("Hinzufügen", systemImage: "plus") }
                    .disabled(model.running)
                Menu {
                    Button("Fertige entfernen") { model.clearFinished() }
                    Button("Liste leeren") { model.archives.removeAll() }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(model.running)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
                if model.archives.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 42, weight: .light))
                            .foregroundColor(model.dropTargeted ? .accentColor : .secondary)
                        Text("Archive aus dem Finder hier ablegen").font(.headline)
                        Text("Eine Datei oder mehrere gleichzeitig\n7z · RAR · ZIP · TAR · und weitere")
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button("Dateien auswählen …") { model.addFromPanel() }
                    }.padding(24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.archives) { item in
                                archiveRow(item)
                                if item.id != model.archives.last?.id { Divider().padding(.horizontal, 12) }
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                }
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.18),
                                  lineWidth: model.dropTargeted ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted, perform: acceptDrop)
            Text("Für mehrteilige Archive die erste Datei ablegen; weitere Teile bleiben daneben im Finder.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func archiveRow(_ item: ArchiveItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.state.symbol).font(.system(size: 20))
                .foregroundColor(item.state.color).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.url.lastPathComponent).fontWeight(.medium).lineLimit(1).help(item.url.path)
                    Spacer()
                    Text(item.state.rawValue).font(.caption).fontWeight(.semibold)
                        .foregroundColor(item.state.color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(item.state.color.opacity(0.09)).cornerRadius(4)
                }
                Text(item.detail).font(.caption).foregroundColor(.secondary)
                    .lineLimit(3).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button { model.chooseDestination(for: item.id) } label: {
                        Label(item.destination?.lastPathComponent ?? "Standardziel", systemImage: "folder")
                            .font(.caption).lineLimit(1)
                    }.buttonStyle(.borderless).disabled(model.running)
                        .help(item.destination?.path ?? model.destination?.path ?? "Ziel wählen")
                    if item.destination != nil {
                        Button { model.resetDestination(item.id) } label: { Image(systemName: "arrow.uturn.backward").font(.caption) }
                            .buttonStyle(.borderless).disabled(model.running).help("Standardziel verwenden")
                    }
                    Spacer()
                    if let output = item.output {
                        Button("Im Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: output.path) }
                            .font(.caption).buttonStyle(.borderless)
                    }
                    Button { model.removeArchive(item.id) } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.borderless).foregroundColor(.secondary).disabled(model.running)
                        .help("Aus der Batchliste entfernen")
                }
            }
        }
        .padding(12)
        .background(model.activeArchiveID == item.id ? Color.accentColor.opacity(0.045) : Color.clear)
        .contextMenu {
            Button("Quelle im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if let output = item.output { Button("Entpackten Ordner öffnen") { NSWorkspace.shared.open(output) } }
            if let password = item.matchedPassword {
                Button("Passendes Passwort kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                }
            }
            if !model.running {
                Button("Eigenes Ziel wählen …") { model.chooseDestination(for: item.id) }
                Button("Entfernen") { model.removeArchive(item.id) }
            }
        }
    }

    private var passwordPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Passwörter").font(.headline)
                Text("\(model.passwords.count)").foregroundColor(.secondary)
                Spacer()
                Button("Text importieren …") { model.importPasswords() }.disabled(model.running)
            }
            HStack(spacing: 6) {
                TextField("Passwort eingeben + Enter", text: $model.passwordInput)
                    .textFieldStyle(.roundedBorder).focused($passwordFocused)
                    .onSubmit { model.addPassword(); passwordFocused = true }
                    .disabled(model.running)
                Button { model.addPassword(); passwordFocused = true } label: { Image(systemName: "plus") }
                    .disabled(model.running || model.passwordInput.isEmpty).help("Passwort hinzufügen")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor))
                if model.passwords.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "key").font(.system(size: 30, weight: .light)).foregroundColor(.secondary)
                        Text("Eine Möglichkeit pro Zeile").font(.subheadline)
                        Text("Enter fügt das Passwort hinzu.\nOder eine Textdatei importieren.")
                            .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }.padding()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.passwords.enumerated()), id: \.element.id) { index, item in
                                    passwordRow(item, index: index).id(item.id)
                                    if item.id != model.passwords.last?.id { Divider().padding(.horizontal, 10) }
                                }
                            }
                        }
                        .onChange(of: model.activePasswordID) { id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                }
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18))
                    .allowsHitTesting(false)
            }
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("Rot = wird gerade getestet").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Leeren") { model.passwords.removeAll() }.font(.caption)
                    .disabled(model.running || model.passwords.isEmpty)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Passwortdatei", systemImage: "externaldrive").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("Speicherort …") { model.choosePasswordLocation() }
                        .font(.caption).disabled(model.running)
                }
                Text(model.passwordListURL?.path ?? "Noch kein Speicherort gewählt")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    .textSelection(.enabled).help(model.passwordListURL?.path ?? "")
                Text(model.passwordStorageMessage).font(.caption)
                    .foregroundColor(model.passwordStorageFailed ? .orange : .secondary)
                    .lineLimit(3).help(model.passwordStorageMessage)
                if model.passwordStorageFailed {
                    Button("Erneut laden / speichern") { model.retryPasswordStorage() }
                        .font(.caption).disabled(model.running)
                }
            }
            Text("Textimport: Leerzeichen, Tabs und Absätze trennen Passwörter.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxHeight: .infinity)
    }

    private func passwordRow(_ item: PasswordItem, index: Int) -> some View {
        let active = model.activePasswordID == item.id
        return HStack(spacing: 8) {
            Text("\(index + 1)").font(.caption).foregroundColor(active ? .red : .secondary).frame(width: 22)
            Text(verbatim: item.value).font(.system(.body, design: .monospaced))
                .foregroundColor(active ? .red : .primary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if active {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundColor(.red)
            } else if item.successes > 0 {
                Label("\(item.successes)", systemImage: "checkmark").font(.caption).foregroundColor(.green)
            }
            Button { model.removePassword(item.id) } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless).foregroundColor(.secondary).disabled(model.running)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(active ? Color.red.opacity(0.07) : Color.clear)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.message).font(.subheadline).lineLimit(2)
                if model.running {
                    HStack {
                        ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                            .progressViewStyle(.linear).frame(maxWidth: 360)
                        Text("\(model.completed) / \(model.total)").font(.caption).foregroundColor(.secondary)
                    }
                } else if model.destination == nil {
                    Text("Zum Starten zuerst den Zielordner wählen.").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if model.running {
                Button(model.stopping ? "Stoppt …" : "Stopp") { model.stop() }
                    .disabled(model.stopping).keyboardShortcut(".", modifiers: .command)
            } else {
                Button { model.start() } label: { Label("Start", systemImage: "play.fill").padding(.horizontal, 16) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canStart).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.running else { return false }
        let collector = DropCollector(count: providers.count)
        for (index, provider) in providers.enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                if let urls = collector.receive(url, index: index) {
                    DispatchQueue.main.async { model.addArchives(urls) }
                }
            }
        }
        return !providers.isEmpty
    }
}

final class DropCollector {
    private let lock = NSLock()
    private var remaining: Int
    private var items: [Int: URL] = [:]
    init(count: Int) { remaining = count }
    func receive(_ url: URL?, index: Int) -> [URL]? {
        lock.lock(); defer { lock.unlock() }
        if let url { items[index] = url }
        remaining -= 1
        return remaining == 0 ? items.keys.sorted().compactMap { items[$0] } : nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        BatchModel.shared.addArchives(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard BatchModel.shared.running else { return confirmPasswordSaveBeforeQuitting() ? .terminateNow : .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "Laufende Verarbeitung stoppen und beenden?"
        alert.informativeText = "Bereits entpackte Archive bleiben erhalten."
        alert.addButton(withTitle: "Stoppen und beenden")
        alert.addButton(withTitle: "Weiterarbeiten")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        BatchModel.shared.stop()
        waitUntilStopped(sender)
        return .terminateLater
    }
    private func confirmPasswordSaveBeforeQuitting() -> Bool {
        let model = BatchModel.shared
        guard model.hasUnsavedPasswords else { return true }
        let alert = NSAlert()
        alert.messageText = "Die Passwortliste ist noch nicht gespeichert"
        alert.informativeText = model.passwordStorageMessage + "\n\nWähle einen erreichbaren Speicherort, um die aktuelle Liste zu behalten."
        alert.addButton(withTitle: "Speicherort wählen …")
        alert.addButton(withTitle: "Ohne Speichern beenden")
        alert.addButton(withTitle: "Abbrechen")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.choosePasswordLocation()
            return !model.hasUnsavedPasswords
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func waitUntilStopped(_ sender: NSApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if BatchModel.shared.running { self.waitUntilStopped(sender) }
            else { sender.reply(toApplicationShouldTerminate: self.confirmPasswordSaveBeforeQuitting()) }
        }
    }
}

@main
struct ArchivBatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("ArchivBatch") { ContentView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Archive hinzufügen …") { BatchModel.shared.addFromPanel() }
                        .keyboardShortcut("o").disabled(BatchModel.shared.running)
                }
                CommandGroup(after: .importExport) {
                    Button("Passwortliste einlesen …") { BatchModel.shared.importPasswords() }
                        .keyboardShortcut("i").disabled(BatchModel.shared.running)
                }
                CommandGroup(replacing: .help) {
                    Button("Kurzanleitung") {
                        let alert = NSAlert()
                        alert.messageText = "ArchivBatch"
                        alert.informativeText = "1. Zielordner wählen.\n2. Archive aus dem Finder ablegen.\n3. Passwörter mit Enter hinzufügen oder Text importieren.\n4. Start drücken.\n\nRot markiert das gerade geprüfte Passwort. Die Passwortliste wird automatisch in der gewählten Textdatei gespeichert; der Speicherort kann beim Start oder unter Passwortdatei geändert werden. Beim Textimport trennen Leerzeichen, Tabs und Absätze die Passwörter. Jedes Archiv erhält einen eigenen Unterordner. Kein Treffer kann auch ein beschädigtes Archiv bedeuten. Mehrteilige Archive: nur den ersten Teil hinzufügen; alle Teile müssen nebeneinander liegen."
                        alert.runModal()
                    }
                }
            }
    }
}
