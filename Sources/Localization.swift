import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", german = "de", french = "fr", spanish = "es"
    case portuguese = "pt-BR", chinese = "zh-Hans", japanese = "ja", hindi = "hi", arabic = "ar"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .portuguese: return "Português (Brasil)"
        case .chinese: return "简体中文"
        case .japanese: return "日本語"
        case .hindi: return "हिन्दी"
        case .arabic: return "العربية"
        }
    }
    var isRightToLeft: Bool { self == .arabic }
    var locale: Locale { Locale(identifier: rawValue) }
}

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    static let preferenceKey = "local.archivbatch.interfaceLanguage"
    @Published private(set) var language: AppLanguage
    let catalogs: [String: [String: String]]
    let resourceDirectory: URL
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, catalogDirectory: URL? = nil) {
        self.defaults = defaults
        self.language = defaults.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .english
        if let catalogDirectory {
            resourceDirectory = catalogDirectory
        } else if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            resourceDirectory = resources.appendingPathComponent("Localization", isDirectory: true)
        } else {
            resourceDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Localization", isDirectory: true)
        }
        var loaded: [String: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let file = resourceDirectory.appendingPathComponent(language.rawValue + ".json")
            if let data = try? Data(contentsOf: file), let catalog = try? JSONDecoder().decode([String: String].self, from: data) {
                loaded[language.rawValue] = catalog
            }
        }
        catalogs = loaded
    }

    func select(_ language: AppLanguage, persist: Bool = true) {
        self.language = language
        if persist {
            defaults.set(language.rawValue, forKey: Self.preferenceKey)
            // App-domain setting only. AppKit reads this before the next native startup.
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    func configureNativeLanguage() {
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }

    func template(_ key: String, language: AppLanguage? = nil) -> String {
        let code = (language ?? self.language).rawValue
        return catalogs[code]?[key] ?? catalogs[AppLanguage.english.rawValue]?[key] ?? key
    }

    func text(_ key: String, arguments: [Any] = []) -> String {
        let format = template(key)
        guard !arguments.isEmpty else { return format }
        let values: [CVarArg] = arguments.map { value in
            switch value {
            case let message as LocalizedMessage: return message.rendered(using: self) as NSString
            case let string as String: return string as NSString
            case let value as Int: return value
            case let value as Int32: return value
            case let value as Double: return value
            case let error as Error: return error.localizedDescription as NSString
            default: return String(describing: value) as NSString
            }
        }
        return String(format: format, locale: language.locale, arguments: values)
    }
}

/// Keep the key and literal arguments, rather than a sentence in a previous language.
/// Filenames, paths and password bytes are never passed through the translation catalog.
struct LocalizedMessage: CustomStringConvertible, ExpressibleByStringLiteral {
    private let key: String?
    private let literal: String
    private let arguments: [Any]
    init(key: String, arguments: [Any] = []) {
        self.key = key
        self.literal = ""
        self.arguments = arguments
    }
    init(stringLiteral value: String) {
        key = nil
        literal = value
        arguments = []
    }
    static func verbatim(_ value: String) -> LocalizedMessage {
        LocalizedMessage(literal: value)
    }
    private init(literal: String) { key = nil; self.literal = literal; arguments = [] }
    func rendered(using localization: AppLocalization = .shared) -> String {
        guard let key else { return literal }
        return localization.text(key, arguments: arguments)
    }
    var description: String { rendered() }
}

func M(_ key: String, _ arguments: Any...) -> LocalizedMessage {
    LocalizedMessage(key: key, arguments: arguments)
}

func T(_ key: String, _ arguments: Any...) -> String {
    AppLocalization.shared.text(key, arguments: arguments)
}
