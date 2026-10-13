import Foundation
import Security

// MARK: - Configuração (salva em ~/Documents/Sussurro/config.json; chaves em ~/Library/Application Support/Sussurro/keys.json)

enum ProviderKind: String, Codable, CaseIterable {
    case openai, anthropic, deepgram
    var label: String {
        switch self {
        case .openai: "Compatível com OpenAI"
        case .anthropic: "Anthropic"
        case .deepgram: "Deepgram"
        }
    }
    var transcribes: Bool { self != .anthropic }
    var writes: Bool { self != .deepgram }
}

struct Provider: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var key: String { Keys.get(id) }

    static let presets: [Provider] = [
        .init(id: "openai", name: "OpenAI", kind: .openai, baseURL: "https://api.openai.com/v1"),
        .init(id: "groq", name: "Groq", kind: .openai, baseURL: "https://api.groq.com/openai/v1"),
        .init(id: "anthropic", name: "Anthropic (Claude)", kind: .anthropic, baseURL: "https://api.anthropic.com/v1"),
        .init(id: "gemini", name: "Google Gemini", kind: .openai, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        .init(id: "openrouter", name: "OpenRouter", kind: .openai, baseURL: "https://openrouter.ai/api/v1"),
        .init(id: "deepgram", name: "Deepgram", kind: .deepgram, baseURL: "https://api.deepgram.com/v1"),
        .init(id: "ollama", name: "Ollama (local)", kind: .openai, baseURL: "http://localhost:11434/v1"),
    ]
}

enum ModeKind: String, Codable, CaseIterable {
    case voice, message, email, note, meeting, custom
    var label: String {
        switch self {
        case .voice: "Voz (só transcrição)"
        case .message: "Mensagem (limpeza leve)"
        case .email: "E-mail"
        case .note: "Notas"
        case .meeting: "Reunião (resumo)"
        case .custom: "Personalizado"
        }
    }
    var system: String {
        switch self {
        case .voice: ""
        case .message: """
            You clean up dictated text with the smallest possible edits.
            - Fix punctuation, capitalization, obvious misspellings and homophones.
            - Write clearly spoken numbers and dates as digits.
            - Remove filler words (um, uh, é, hum, ahn), accidental repetitions and explicit self-corrections (keep only the corrected version).
            - Add paragraph breaks only when the text is long or changes topic.
            Do not rephrase, summarize, translate or answer the text. Keep the speaker's language, tone, slang and profanity. Output only the cleaned text.
            """
        case .email: """
            Turn the dictated text into a ready-to-send email body: keep the greeting that was spoken (otherwise add a short one, with the recipient's name if mentioned), clear paragraphs with corrected grammar, and a short sign-off (keep the one spoken).
            No subject line, no signature, nothing added beyond what was said. Keep the speaker's language and tone. Output only the email.
            """
        case .note: """
            Turn the dictated text into concise structured notes: a short title line, then bullet points with the key ideas, decisions and action items.
            Use only information present in the text. Keep the speaker's language. Output only the notes.
            """
        case .meeting: """
            Summarize the meeting transcript: a short overview, main topics as bullet points, decisions, and action items with owners when mentioned.
            Use only what was explicitly said. Keep the transcript's language. Output only the summary.
            """
        case .custom: """
            You are a text transformation function. Follow the instructions to transform, rewrite or respond to the USER MESSAGE, which is dictated speech.
            Output only the result, without preamble or quotes.
            """
        }
    }
}

struct Mode: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var kind: ModeKind = .voice
    var prompt = ""                 // instruções extras; {{user_message}} injeta o texto ditado
    var language = ""               // "" = detectar
    var translateToEnglish = false
    var useClipboard = false
    var useSelection = false
    var useAppContext = false
    var apps = ""                   // bundle IDs (vírgula): o modo liga sozinho nesses apps
    var shortcut = Shortcut.none    // grava já neste modo

    var icon: String {
        ["voice": "mic", "message": "bubble.left", "email": "envelope", "note": "note.text", "meeting": "person.2", "custom": "sparkles"][kind.rawValue]!
    }

    static let defaults: [Mode] = [
        .init(id: "voice", name: "Voz", kind: .voice, language: "pt"),
        .init(id: "message", name: "Mensagem", kind: .message, language: "pt"),
        .init(id: "email", name: "E-mail", kind: .email, language: "pt"),
        .init(id: "note", name: "Notas", kind: .note, language: "pt"),
        .init(id: "meeting", name: "Reunião", kind: .meeting, language: "pt"),
    ]
}

struct Replacement: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var original = ""
    var with = ""
}

// Atalho: tecla modificadora sozinha (ex.: ⌥ direito) ou combinação (ex.: ⌥⇧K)
struct Shortcut: Codable, Hashable {
    var keyCode: UInt16
    var mods: UInt = 0      // NSEvent.ModifierFlags sem lado: ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20
    var key = ""            // nome da tecla para mostrar

    // bits por lado (NX_DEVICE*KEYMASK): ⌥ direito não confunde com o esquerdo
    static let sideMask: [UInt16: UInt] = [61: 0x40, 58: 0x20, 54: 0x10, 55: 0x08, 62: 0x2000, 59: 0x01, 60: 0x04, 56: 0x02, 63: 0x800000]
    static let modSymbol: [UInt16: String] = [61: "⌥", 58: "⌥", 54: "⌘", 55: "⌘", 62: "⌃", 59: "⌃", 60: "⇧", 56: "⇧", 63: "fn"]
    var modifierOnly: Bool { Shortcut.sideMask[keyCode] != nil }

    var caps: [String] {
        if let m = Shortcut.modSymbol[keyCode] { return [m] }
        return [(1 << 18, "⌃"), (1 << 19, "⌥"), (1 << 17, "⇧"), (1 << 20, "⌘")].filter { mods & $0.0 != 0 }.map(\.1) + [key]
    }
    var label: String {
        if let m = Shortcut.modSymbol[keyCode] { return m + ([61, 54, 62, 60].contains(keyCode) ? " direito" : keyCode == 63 ? "" : " esquerdo") }
        return caps.joined()
    }
    var carbonMods: UInt32 {
        [(1 << 20, 0x100), (1 << 17, 0x200), (1 << 19, 0x800), (1 << 18, 0x1000)].reduce(0) { mods & $1.0 != 0 ? $0 | UInt32($1.1) : $0 }
    }

    static let none = Shortcut(keyCode: .max)
    var isNone: Bool { keyCode == .max }
    static let toggle = Shortcut(keyCode: 61, key: "⌥")
    static let cancel = Shortcut(keyCode: 53, key: "esc")
    static let changeMode = Shortcut(keyCode: 40, mods: 1 << 19 | 1 << 17, key: "K")

    static func keyName(_ code: UInt16, _ chars: String?) -> String {
        let names: [UInt16: String] = [53: "esc", 49: "espaço", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
                                       109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15"]
        return names[code] ?? (chars ?? "?").uppercased()
    }
}

struct Config: Codable {
    var providers = Provider.presets
    var sttProvider = "openai"
    var sttModel = "gpt-4o-mini-transcribe"
    var llmProvider = "openai"
    var llmModel = "gpt-5.4-mini"
    var modes = Mode.defaults
    var activeMode = "voice"
    var vocabulary: [String] = []
    var replacements: [Replacement] = []
    // atalhos
    var toggleShortcut = Shortcut.toggle
    var cancelShortcut = Shortcut.cancel
    var changeModeShortcut = Shortcut.changeMode
    var pushToTalkShortcut = Shortcut.none
    // aparência e comportamento
    var theme = "dark"                  // auto, light, dark
    var recordingWindow = "classic"     // classic, mini, none
    var micID = ""                      // "" = microfone padrão do sistema
    var soundStyle = "classic"          // simple, classic, off
    var soundVolume = 0.9
    var muteWhileRecording = false
    var pasteResult = true
    var restoreClipboard = true         // true = mantém o que eu tinha copiado
    var showInDock = false
    var recordOnMenubarClick = false
    var keepDays = 0                    // 0 = para sempre
    var typingWPM = 40

    func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }
    var terms: [String] { vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var mode: Mode { modes.first { $0.id == activeMode } ?? modes.first ?? Mode.defaults[0] }

    // Campos novos ganham o valor padrão; se mesmo assim não ler, guarda cópia antes de recomeçar.
    static func load(from url: URL) -> Config {
        guard let d = try? Data(contentsOf: url) else { return Config() }
        func dict<T: Encodable>(_ v: T) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) as? [String: Any] ?? [:]
        }
        if var saved = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, def) in [("modes", dict(Mode(name: ""))), ("providers", dict(Provider(name: "", kind: .openai, baseURL: ""))),
                             ("replacements", dict(Replacement()))] {
                if let arr = saved[k] as? [[String: Any]] { saved[k] = arr.map { def.merging($0) { $1 } } }
            }
            saved = dict(Config()).merging(saved) { $1 }
            if let m = try? JSONSerialization.data(withJSONObject: saved), let c = try? JSONDecoder().decode(Config.self, from: m) { return c }
        }
        try? FileManager.default.copyItem(at: url, to: url.deletingPathExtension().appendingPathExtension("bak.json"))
        return Config()
    }
}

enum Paths {
    static let dir = ProcessInfo.processInfo.environment["SUSSURRO_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Sussurro")
    static let config = dir.appendingPathComponent("config.json")
    static let recordings = dir.appendingPathComponent("recordings")
}

// MARK: - Texto

struct Context {
    var app: String?
    var clipboard: String?
    var selection: String?
}

enum TextKit {
    static func replace(_ s: String, _ reps: [Replacement]) -> String {
        reps.filter { !$0.original.isEmpty }.reduce(s) { s, r in
            let re = try! NSRegularExpression(pattern: "(?<!\\w)" + NSRegularExpression.escapedPattern(for: r.original) + "(?!\\w)", options: .caseInsensitive)
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: r.with))
        }
    }

    static func stripThink(_ s: String) -> String {
        s.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(mode: Mode, text: String, ctx: Context, vocabulary: [String]) -> (system: String, user: String) {
        var system = mode.kind == .voice ? ModeKind.custom.system : mode.kind.system
        if !vocabulary.isEmpty { system += "\nSpell these terms exactly like this: " + vocabulary.joined(separator: ", ") }
        let macro = mode.prompt.contains("{{user_message}}")
        if !mode.prompt.isEmpty && !macro { system += "\n\nInstructions:\n" + mode.prompt }
        var parts: [String] = []
        if let a = ctx.app { parts.append("ACTIVE APPLICATION: \(a)") }
        if let c = ctx.clipboard { parts.append("CLIPBOARD CONTENT (background only, do not copy it into the output unless asked):\n\(c)") }
        if let s = ctx.selection { parts.append("SELECTED TEXT:\n\(s)") }
        parts.append(macro ? mode.prompt.replacingOccurrences(of: "{{user_message}}", with: text) : "USER MESSAGE:\n" + text)
        return (system, parts.joined(separator: "\n\n"))
    }
}

// MARK: - Histórico (recordings/<data>/meta.json + áudio)

struct Entry: Codable {
    var date = Date()
    var mode = ""
    var audio = "audio.wav"
    var raw = ""
    var result = ""
    var duration = 0.0
    var models = ""
    var app: String?
    var error: String?

    var words: Int { result.split(whereSeparator: \.isWhitespace).count }

    static func load(_ dir: URL) -> Entry? {
        try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
    }
    func save(_ dir: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]
        try? e.encode(self).write(to: dir.appendingPathComponent("meta.json"))
    }
}

// MARK: - Chaves de API (~/Library/Application Support/Sussurro/keys.json, só o seu usuário lê)
// ponytail: saiu do Chaves do macOS porque sem Team ID da Apple cada build pede a senha de novo;
// volta para o Chaves se o app passar a ser assinado com conta Apple Developer.

enum Keys {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sussurro")
    private static let file = dir.appendingPathComponent("keys.json")
    private static var all: [String: String] = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]

    private static let lock = NSRecursiveLock()   // IA lê fora da main thread, a tela de ajustes escreve na main

    static func get(_ account: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let v = all[account] { return v }
        let v = legacyKeychain(account)   // migração: lê uma última vez do Chaves
        if !v.isEmpty { set(account, v) }
        return v
    }
    static func set(_ account: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        all[account] = value.isEmpty ? nil : value
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let d = try? JSONEncoder().encode(all) else { return }
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
    private static func legacyKeychain(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Sussurro", kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Importar do Superwhisper (~/Documents/superwhisper)

enum SuperwhisperImport {
    static func run(into c: inout Config) -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/superwhisper")
        var n = (0, 0, 0)
        if let d = try? Data(contentsOf: base.appendingPathComponent("settings/settings.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for v in j["vocabulary"] as? [String] ?? [] where !c.vocabulary.contains(v) { c.vocabulary.append(v); n.0 += 1 }
            for r in j["replacements"] as? [[String: Any]] ?? [] {
                guard let o = r["original"] as? String, !c.replacements.contains(where: { $0.original == o }) else { continue }
                c.replacements.append(.init(original: o, with: r["with"] as? String ?? "")); n.1 += 1
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("modes"), includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let key = j["key"] as? String, !c.modes.contains(where: { $0.id == "sw-" + key }) else { continue }
            var m = Mode(id: "sw-" + key, name: (j["name"] as? String ?? key) + " (Superwhisper)")
            m.kind = ModeKind(rawValue: j["type"] as? String ?? "") ?? .custom
            m.prompt = j["prompt"] as? String ?? ""
            m.language = j["language"] as? String ?? ""
            m.translateToEnglish = j["translateToEnglish"] as? Bool ?? false
            m.useClipboard = j["contextFromClipboard"] as? Bool ?? false
            m.useSelection = j["contextFromSelection"] as? Bool ?? false
            m.useAppContext = j["contextFromActiveApplication"] as? Bool ?? false
            m.apps = (j["activationApps"] as? [String] ?? []).joined(separator: ", ")
            c.modes.append(m); n.2 += 1
        }
        return "Importados: \(n.0) termos, \(n.1) substituições, \(n.2) modos."
    }
}
