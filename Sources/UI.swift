import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var cfg: Config { didSet { save() } }
    init() { cfg = Config.load(from: Paths.config); save() }
    func save() {
        try? FileManager.default.createDirectory(at: Paths.recordings, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(cfg).write(to: Paths.config)
    }
}

func loadHistory() -> [(dir: URL, e: Entry)] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.recordings, includingPropertiesForKeys: nil)) ?? []
    return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { d in Entry.load(d).map { (d, $0) } }
}

// MARK: - Peças visuais (cartões e linhas no estilo do Superwhisper)

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subs in
                ForEach(subs.indices, id: \.self) { i in
                    if i > 0 { Divider().padding(.horizontal, 14) }
                    subs[i]
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

struct Row<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var help: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13))
                    if let help { Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).help(help) }
                }
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }
}

struct SectionTitle: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6) }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

struct IconTile: View {
    var symbol: String
    var color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

// MARK: - Gravador de atalho

struct ShortcutField: View {
    @Binding var value: Shortcut
    var defaultValue = Shortcut.none
    @ObservedObject var nav: Nav
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var pendingMod: UInt16?

    var body: some View {
        HStack(spacing: 8) {
            if value != defaultValue && !defaultValue.isNone {
                Button { value = defaultValue } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Voltar ao padrão")
            }
            Button { capturing ? stop() : start() } label: {
                Group {
                    if capturing { Text("Pressione o atalho…").foregroundStyle(Color.accentColor) }
                    else if value.isNone { Text("Gravar atalho").foregroundStyle(.tertiary) }
                    else { KeyCaps(caps: value.caps) }
                }
                .padding(.horizontal, capturing || value.isNone ? 8 : 0).frame(minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6).stroke(capturing ? Color.accentColor : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(value.isNone ? "Clique e pressione as teclas" : value.label)
            if !value.isNone && !capturing {
                Button { value = .none } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remover atalho")
            }
        }
        .font(.system(size: 12))
        .onDisappear { stop() }
    }

    func start() {
        capturing = true
        nav.capturing = true
        pendingMod = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            if e.type == .keyDown {
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
                value = Shortcut(keyCode: e.keyCode, mods: mods, key: Shortcut.keyName(e.keyCode, e.charactersIgnoringModifiers))
                stop()
                return nil
            }
            // modificador sozinho (ex.: ⌥ direito): vale quando solta sem apertar outra tecla
            if let mask = Shortcut.sideMask[e.keyCode] {
                if e.modifierFlags.rawValue & mask != 0 { pendingMod = e.keyCode }
                else if pendingMod == e.keyCode { value = Shortcut(keyCode: e.keyCode, key: Shortcut.modSymbol[e.keyCode]!); stop() }
            }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        capturing = false
        if nav.capturing { nav.capturing = false }
    }
}

// MARK: - Janela principal

struct MainView: View {
    @ObservedObject var store: Store
    @ObservedObject var nav: Nav
    let app: AppDelegate

    var body: some View {
        HStack(spacing: 0) {
            if nav.sidebar {
                Sidebar(nav: nav).frame(width: 220)
                Divider()
            }
            VStack(spacing: 0) {
                toolbar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(dyn(0.2, 0.97))
        }
        .ignoresSafeArea()
        .font(.system(size: 13))
    }

    var subpage: Bool { nav.modeID != nil || nav.advanced }

    var toolbar: some View {
        HStack(spacing: 12) {
            if subpage {
                Button { nav.modeID = nil; nav.advanced = false } label: { Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            } else {
                Button { withAnimation(.easeOut(duration: 0.2)) { nav.sidebar.toggle() } } label: { Image(systemName: "sidebar.left").font(.system(size: 15)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = nav.modeID, let m = store.cfg.modes.first(where: { $0.id == id }) {
                Label(m.name, systemImage: m.icon).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Menu {
                Button { store.cfg.micID = "" } label: { Text((store.cfg.micID.isEmpty ? "✓ " : "") + "Padrão do sistema") }
                Divider()
                ForEach(MicRecorder.devices(), id: \.uniqueID) { d in
                    Button { store.cfg.micID = d.uniqueID } label: { Text((store.cfg.micID == d.uniqueID ? "✓ " : "") + d.localizedName) }
                }
            } label: {
                Text(MicRecorder.name(store.cfg.micID)).font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Image(systemName: "headphones").foregroundStyle(.secondary)
        }
        .padding(.leading, nav.sidebar ? 16 : 84)
        .padding(.trailing, 16)
        .frame(height: 52)
    }

    @ViewBuilder var content: some View {
        switch nav.page {
        case .home: HomePage(store: store, nav: nav, app: app)
        case .modes:
            if let id = nav.modeID, store.cfg.modes.contains(where: { $0.id == id }) {
                ModeDetail(store: store, nav: nav, id: id).id(id)
            } else { ModesPage(store: store, nav: nav) }
        case .vocabulary: VocabularyPage(store: store)
        case .config: if nav.advanced { AdvancedPage(store: store) } else { ConfigPage(store: store, nav: nav) }
        case .sound: SoundPage(store: store)
        case .models: ModelsPage(store: store)
        case .history: HistoryPage(app: app)
        }
    }
}

struct Sidebar: View {
    @ObservedObject var nav: Nav
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            item(.home, "Início", "house.fill", .orange)
            Spacer().frame(height: 10)
            item(.modes, "Modos", "sparkle", .blue)
            item(.vocabulary, "Vocabulário", "book.closed.fill", .blue)
            Spacer().frame(height: 10)
            item(.config, "Configuração", "gearshape.fill", .gray)
            item(.sound, "Som", "speaker.wave.2.fill", .gray)
            item(.models, "Modelos e chaves", "key.fill", .gray)
            Spacer().frame(height: 10)
            item(.history, "Histórico", "clock.fill", .purple)
            Spacer()
            HStack(spacing: 8) {
                Text("Sussurro").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                Text("PESSOAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(Capsule().stroke(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 12).padding(.top, 54).padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .background(dyn(0.165, 0.93))
    }

    func item(_ p: Nav.Page, _ title: String, _ symbol: String, _ color: Color) -> some View {
        Button { nav.page = p } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color)
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(nav.page == p ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Início

struct HomePage: View {
    @ObservedObject var store: Store
    @ObservedObject var nav: Nav
    let app: AppDelegate
    @State private var days = 0
    @State private var entries: [Entry] = []
    @State private var showWPM = false

    var body: some View {
        let list = entries.filter { $0.error == nil && (days == 0 || $0.date > Date().addingTimeInterval(-Double(days) * 86400)) }
        let words = list.reduce(0) { $0 + $1.words }
        let minutes = list.reduce(0.0) { $0 + $1.duration } / 60
        let wpm = minutes > 0 ? Int(Double(words) / minutes) : 0
        let saved = max(0, Double(words) / Double(max(1, store.cfg.typingWPM)) - minutes)
        Page {
            HStack {
                Menu {
                    ForEach([(0, "Desde sempre"), (1, "Hoje"), (7, "Últimos 7 dias"), (30, "Últimos 30 dias")], id: \.0) { d, t in
                        Button(t) { days = d }
                    }
                } label: {
                    Text([0: "Desde sempre", 1: "Hoje", 7: "Últimos 7 dias", 30: "Últimos 30 dias"][days]!).font(.system(size: 15, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            HStack(alignment: .top) {
                stat("\(wpm) WPM", "Velocidade média")
                stat(words.formatted(), "Palavras")
                stat("\(Set(list.compactMap(\.app)).count)", "Apps usados")
                VStack(alignment: .leading, spacing: 6) {
                    Text(duration(saved)).font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 4) {
                        Text("Economizado").foregroundStyle(.secondary)
                        Button { showWPM.toggle() } label: { Image(systemName: "gearshape.fill").font(.system(size: 11)) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .popover(isPresented: $showWPM) {
                                Stepper("Você digita \(store.cfg.typingWPM) palavras por minuto", value: $store.cfg.typingWPM, in: 10...150, step: 5).padding()
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
            SectionTitle("Primeiros passos").padding(.top, 8)
            VStack(spacing: 4) {
                step("record.circle", "Iniciar gravação", "Transforme sua voz em texto com um clique.", caps: store.cfg.toggleShortcut.caps) { app.toggleRecording() }
                step("hand.point.up.left", "Personalizar atalhos", "Mude os atalhos de teclado do Sussurro.") { nav.page = .config }
                step("key", "Colocar sua chave de API", "Escolha a IA que transcreve e a que reescreve o texto.") { nav.page = .models }
                step("sparkle", "Criar um modo", "Monte o modo perfeito para o seu fluxo.") { nav.page = .modes }
                step("book.closed", "Adicionar vocabulário", "Ensine nomes, termos e palavras do seu trabalho.") { nav.page = .vocabulary }
            }
        }
        .onAppear { entries = loadHistory().map(\.e) }
        .onReceive(NotificationCenter.default.publisher(for: .historyChanged)) { _ in entries = loadHistory().map(\.e) }
    }

    func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v).font(.system(size: 16, weight: .semibold))
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func duration(_ minutes: Double) -> String {
        minutes < 60 ? "\(Int(minutes)) min" : minutes < 1440 ? "\(Int(minutes / 60)) h" : "\(Int(minutes / 1440)) dias"
    }

    func step(_ icon: String, _ title: String, _ sub: String, caps: [String]? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(sub).foregroundStyle(.secondary)
                }
                Spacer()
                if let caps { KeyCaps(caps: caps) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Modos

struct ModesPage: View {
    @ObservedObject var store: Store
    @ObservedObject var nav: Nav

    var body: some View {
        VStack(spacing: 0) {
            Page {
                HStack {
                    Text("Modos").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        let m = Mode(name: "Novo modo", kind: .custom)
                        store.cfg.modes.append(m)
                        nav.modeID = m.id
                    } label: { Label("Criar modo", systemImage: "plus") }
                }
                ForEach(store.cfg.modes) { m in
                    Button { nav.modeID = m.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: m.icon).foregroundStyle(.secondary).frame(width: 20)
                            Text(m.name).font(.system(size: 13.5))
                            if m.id == store.cfg.activeMode { Circle().fill(.green).frame(width: 7, height: 7) }
                            Spacer()
                            Text(m.kind.label).foregroundStyle(.tertiary).font(.system(size: 12))
                            if !m.shortcut.isNone { KeyCaps(caps: m.shortcut.caps) }
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                KeyCaps(caps: store.cfg.changeModeShortcut.caps)
                Text("Trocar modo ativo").foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
        }
    }
}

let languages = [("", "Detectar sozinho"), ("pt", "Português"), ("en", "Inglês"), ("es", "Espanhol"), ("fr", "Francês"),
                 ("de", "Alemão"), ("it", "Italiano"), ("ja", "Japonês"), ("zh", "Chinês")]

struct ModeDetail: View {
    @ObservedObject var store: Store
    @ObservedObject var nav: Nav
    let id: String

    var m: Binding<Mode> {
        Binding(get: { store.cfg.modes.first { $0.id == id } ?? Mode(name: "") },
                set: { v in if let i = store.cfg.modes.firstIndex(where: { $0.id == id }) { store.cfg.modes[i] = v } })
    }

    var body: some View {
        let c = store.cfg
        Page {
            Card {
                Row(title: "Nome") {
                    TextField("", text: m.name).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(maxWidth: 260)
                }
                Row(title: "Predefinição", help: "O que a IA faz com o texto. “Voz” não usa IA: o texto sai como foi falado.") {
                    Picker("", selection: m.kind) { ForEach(ModeKind.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                }
            }
            Card {
                Row(title: "Idioma") {
                    Picker("", selection: m.language) { ForEach(languages, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().fixedSize()
                }
                Row(title: "Modelo de voz", help: "Vale para todos os modos. Troque em Modelos e chaves.") {
                    Button("\(c.provider(c.sttProvider)?.name ?? "?") · \(c.sttModel)") { nav.page = .models }.buttonStyle(.borderless)
                }
                if m.wrappedValue.kind != .voice || !m.wrappedValue.prompt.isEmpty {
                    Row(title: "Modelo de texto", help: "Vale para todos os modos. Troque em Modelos e chaves.") {
                        Button("\(c.provider(c.llmProvider)?.name ?? "?") · \(c.llmModel)") { nav.page = .models }.buttonStyle(.borderless)
                    }
                }
            }
            Card {
                Row(title: "Ativar nos apps", help: "Ao gravar com um destes apps na frente, este modo é usado sozinho.") {
                    Button("Adicionar apps") { pickApp() }
                }
                if !appIDs.isEmpty {
                    HStack {
                        ForEach(appIDs, id: \.self) { b in
                            HStack(spacing: 4) {
                                Text(appName(b))
                                Button { m.wrappedValue.apps = appIDs.filter { $0 != b }.joined(separator: ", ") } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).font(.system(size: 9, weight: .bold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                Row(title: "Atalho do teclado", subtitle: "Começa a gravar neste modo") { ShortcutField(value: m.shortcut, nav: nav) }
            }
            DisclosureGroup(isExpanded: $nav.advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instruções para a IA").font(.system(size: 13))
                            TextEditor(text: m.prompt).font(.system(size: 13)).frame(minHeight: 110).scrollContentBackground(.hidden)
                                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                            Text(m.wrappedValue.kind == .voice
                                 ? "Em Voz, sem instruções o texto sai direto da transcrição. Com instruções, passa pelo modelo de texto."
                                 : "Opcional: acrescenta ao comportamento da predefinição. Use {{user_message}} para dizer onde entra o texto ditado.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(14)
                    }
                    Card {
                        Row(title: "Usar o que está copiado", help: "Manda o conteúdo da área de transferência como contexto.") { Toggle("", isOn: m.useClipboard).labelsHidden().toggleStyle(.switch) }
                        Row(title: "Usar o texto selecionado", help: "Manda o texto selecionado no app como contexto (ex.: “reescreve isso mais formal”).") { Toggle("", isOn: m.useSelection).labelsHidden().toggleStyle(.switch) }
                        Row(title: "Usar o nome do app em uso") { Toggle("", isOn: m.useAppContext).labelsHidden().toggleStyle(.switch) }
                        Row(title: "Traduzir para inglês", help: "Precisa de um modelo whisper-1 ou whisper-large-v3.") { Toggle("", isOn: m.translateToEnglish).labelsHidden().toggleStyle(.switch) }
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Configurações avançadas").font(.system(size: 13, weight: .medium))
            }
            HStack {
                Button(c.activeMode == id ? "Modo em uso" : "Usar este modo") { store.cfg.activeMode = id }.disabled(c.activeMode == id)
                Spacer()
                Button("Excluir modo", role: .destructive) {
                    store.cfg.modes.removeAll { $0.id == id }
                    if !store.cfg.modes.contains(where: { $0.id == store.cfg.activeMode }) { store.cfg.activeMode = store.cfg.modes.first?.id ?? "" }
                    nav.modeID = nil
                }
                .disabled(c.modes.count < 2)
            }
            .padding(.top, 8)
        }
    }

    var appIDs: [String] { m.wrappedValue.apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }

    func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK else { return }
        let ids = appIDs + p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        m.wrappedValue.apps = Array(NSOrderedSet(array: ids)).compactMap { $0 as? String }.joined(separator: ", ")
    }
}

// MARK: - Vocabulário

struct VocabularyPage: View {
    @ObservedObject var store: Store
    @State private var text = ""
    @State private var original: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(original.map { "Substituir “\($0)” por…" } ?? "Nova palavra ou substituição", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .onSubmit(add)
                    .onKeyPress(.return, phases: .down) { k in
                        guard k.modifiers.contains(.command), original == nil else { return .ignored }
                        replaceWith()
                        return .handled
                    }
                    .onKeyPress(.escape) { original = nil; text = ""; return .handled }
                if original == nil {
                    hint("Adicionar palavra", ["↩"], add)
                    hint("Substituir por…", ["⌘", "↩"], replaceWith)
                } else {
                    hint("Salvar", ["↩"], add)
                    hint("Cancelar", ["esc"]) { original = nil; text = "" }
                }
            }
            .padding(.horizontal, 14).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.15)))
            .padding(16)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.cfg.replacements) { r in
                        line {
                            Text(r.original).frame(width: 180, alignment: .leading)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
                            Text(r.with).padding(.leading, 10)
                        } remove: { store.cfg.replacements.removeAll { $0.id == r.id } }
                    }
                    ForEach(store.cfg.terms, id: \.self) { w in
                        line { Text(w) } remove: { store.cfg.vocabulary.removeAll { $0.trimmingCharacters(in: .whitespaces) == w } }
                    }
                }
                .padding(.horizontal, 16)
            }
            .overlay {
                if store.cfg.terms.isEmpty && store.cfg.replacements.isEmpty {
                    Text("Adicione nomes, siglas e termos do seu trabalho.\nEles ajudam a transcrição e a IA a escrever certo.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { focused = true }
    }

    func add() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let o = original {
            if !t.isEmpty { store.cfg.replacements.append(Replacement(original: o, with: t)) }
            original = nil
        } else if !t.isEmpty, !store.cfg.terms.contains(t) {
            store.cfg.vocabulary = store.cfg.terms + [t]
        }
        text = ""
    }

    func replaceWith() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        original = t
        text = ""
    }

    func hint(_ title: String, _ caps: [String], _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 6) { Text(title); KeyCaps(caps: caps).scaleEffect(0.85) } }
            .buttonStyle(.plain).foregroundStyle(.tertiary).font(.system(size: 12))
    }

    func line<C: View>(@ViewBuilder _ content: () -> C, remove: @escaping () -> Void) -> some View {
        HoverRow(content: content(), remove: remove)
    }
}

struct HoverRow<C: View>: View {
    var content: C
    var remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 0) {
            content
            Spacer()
            if hover { Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.05) : .clear))
        .onHover { hover = $0 }
    }
}

// MARK: - Configuração

struct ConfigPage: View {
    @ObservedObject var store: Store
    @ObservedObject var nav: Nav
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Page {
            SectionTitle("Aparência")
            Card {
                Row(title: "Tema") {
                    HStack(spacing: 10) {
                        tile("Auto", store.cfg.theme == "auto") { store.cfg.theme = "auto" } art: {
                            HStack(spacing: 0) { Color(white: 0.92); Color(white: 0.18) }
                        }
                        tile("Claro", store.cfg.theme == "light") { store.cfg.theme = "light" } art: { Color(white: 0.92) }
                        tile("Escuro", store.cfg.theme == "dark") { store.cfg.theme = "dark" } art: { Color(white: 0.18) }
                    }
                    .padding(.vertical, 10)
                }
                Row(title: "Janela de gravação") {
                    HStack(spacing: 10) {
                        tile("Clássica", store.cfg.recordingWindow == "classic") { store.cfg.recordingWindow = "classic" } art: {
                            ZStack {
                                Color(white: 0.12)
                                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.24)).padding(8)
                                Waveform(levels: (0..<16).map { i in Float(abs(sin(Double(i) * 0.9))) * 0.8 }).frame(width: 40, height: 12)
                            }
                        }
                        tile("Mini", store.cfg.recordingWindow == "mini") { store.cfg.recordingWindow = "mini" } art: {
                            ZStack {
                                Color(white: 0.12)
                                Capsule().fill(Color(white: 0.24)).frame(width: 46, height: 16)
                                Waveform(levels: (0..<8).map { i in Float(abs(sin(Double(i) * 1.3))) * 0.8 }).frame(width: 22, height: 8)
                            }
                        }
                        tile("Nenhuma", store.cfg.recordingWindow == "none") { store.cfg.recordingWindow = "none" } art: {
                            ZStack { Color(white: 0.12); Image(systemName: "eye.slash").foregroundStyle(.gray) }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            SectionTitle("Atalhos de teclado")
            Card {
                Row(title: "Gravar / parar", subtitle: "Toque para começar e terminar; segure para falar enquanto segura") {
                    ShortcutField(value: $store.cfg.toggleShortcut, defaultValue: .toggle, nav: nav)
                }
                Row(title: "Cancelar gravação", subtitle: "Descarta a gravação em andamento ou fecha a janela") {
                    ShortcutField(value: $store.cfg.cancelShortcut, defaultValue: .cancel, nav: nav)
                }
                Row(title: "Trocar modo", subtitle: "Passa para o próximo modo") {
                    ShortcutField(value: $store.cfg.changeModeShortcut, defaultValue: .changeMode, nav: nav)
                }
                Row(title: "Push to talk", subtitle: "Segure para gravar, solte quando terminar") {
                    ShortcutField(value: $store.cfg.pushToTalkShortcut, nav: nav)
                }
            }
            SectionTitle("Aplicativo")
            Card {
                Row(title: "Abrir ao iniciar sessão", help: "Abre o Sussurro sozinho quando você liga o Mac.") {
                    Toggle("", isOn: $login).labelsHidden().toggleStyle(.switch)
                        .onChange(of: login) { _, on in
                            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        }
                }
                Row(title: "Apagar áudios depois de", help: "Apaga sozinho os arquivos de áudio (confere a cada hora). O texto e as métricas do Início continuam.") {
                    Picker("", selection: $store.cfg.keepDays) {
                        Text("Nunca").tag(0); Text("1 dia").tag(1); Text("7 dias").tag(7); Text("30 dias").tag(30)
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: store.cfg.keepDays) { _, _ in (NSApp.delegate as? AppDelegate)?.cleanOldRecordings() }
                }
            }
            Button { nav.advanced = true } label: {
                HStack { Text("Configurações avançadas"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                    .padding(.horizontal, 14).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 8)
        }
    }

    func tile<A: View>(_ title: String, _ on: Bool, _ action: @escaping () -> Void, @ViewBuilder art: () -> A) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                art().frame(width: 84, height: 50).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: on ? 2.5 : 1))
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AdvancedPage: View {
    @ObservedObject var store: Store
    @State private var ax = AXIsProcessTrusted()
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var msg = ""

    var body: some View {
        Page {
            SectionTitle("Aplicativo")
            Card {
                Row(title: "Mostrar no Dock") { Toggle("", isOn: $store.cfg.showInDock).labelsHidden().toggleStyle(.switch) }
                Row(title: "Gravar ao clicar na barra de menus", help: "Clique esquerdo grava; clique direito abre o menu.") {
                    Toggle("", isOn: $store.cfg.recordOnMenubarClick).labelsHidden().toggleStyle(.switch)
                }
            }
            SectionTitle("Pasta do app")
            Card {
                Row(title: Paths.dir.path) { Button("Abrir pasta") { NSWorkspace.shared.open(Paths.dir) } }
                Row(title: "Importar do Superwhisper", subtitle: msg.isEmpty ? "Modos, vocabulário e substituições" : msg) {
                    Button("Importar") { msg = SuperwhisperImport.run(into: &store.cfg) }
                }
            }
            SectionTitle("Texto")
            Card {
                Row(title: "Área de transferência", help: "Quando o texto é colado num campo: devolver o que você tinha copiado antes ou deixar o resultado copiado. Sem campo de texto, o resultado sempre fica no ⌘V.") {
                    Picker("", selection: $store.cfg.restoreClipboard) {
                        Text("Manter o que eu copiei").tag(true)
                        Text("Deixar o resultado copiado").tag(false)
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Colar o resultado", help: "Desligado: o texto aparece na janela de gravação e fica no ⌘V.") {
                    Toggle("", isOn: $store.cfg.pasteResult).labelsHidden().toggleStyle(.switch)
                }
            }
            SectionTitle("Permissões")
            Card {
                Row(title: "Microfone") { status(mic, "Privacy_Microphone") }
                Row(title: "Acessibilidade", subtitle: "Atalhos, detectar o campo de texto e colar") { status(ax, "Privacy_Accessibility") }
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            ax = AXIsProcessTrusted()
            mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    func status(_ ok: Bool, _ pane: String) -> some View {
        HStack {
            Text(ok ? "Liberado" : "Pendente").foregroundStyle(ok ? .green : .orange)
            if !ok {
                Button("Abrir Ajustes") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
            }
        }
    }
}

// MARK: - Som

struct SoundPage: View {
    @ObservedObject var store: Store
    var body: some View {
        Page {
            SectionTitle("Gravação")
            Card {
                Row(title: "Silenciar o Mac enquanto grava", help: "Tira o som do Mac durante a gravação e devolve no fim.") {
                    Toggle("", isOn: $store.cfg.muteWhileRecording).labelsHidden().toggleStyle(.switch)
                }
            }
            SectionTitle("Efeitos sonoros")
            Card {
                Row(title: "Efeitos sonoros") {
                    Picker("", selection: $store.cfg.soundStyle) {
                        Text("Simples").tag("simple"); Text("Clássico").tag("classic"); Text("Desligado").tag("off")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: store.cfg.soundStyle) { _, _ in preview() }
                }
                Row(title: "Volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $store.cfg.soundVolume, in: 0...1) { editing in if !editing { preview() } }.frame(width: 180)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .disabled(store.cfg.soundStyle == "off")
                }
            }
        }
    }

    func preview() {
        guard store.cfg.soundStyle != "off", let s = NSSound(named: store.cfg.soundStyle == "simple" ? "Tink" : "Purr")?.copy() as? NSSound else { return }
        s.volume = Float(store.cfg.soundVolume)
        s.play()
    }
}

// MARK: - Modelos e chaves

struct ModelsPage: View {
    @ObservedObject var store: Store

    var body: some View {
        Page {
            SectionTitle("Transcrição (voz → texto)")
            Card {
                Row(title: "Provedor") {
                    Picker("", selection: $store.cfg.sttProvider) {
                        ForEach(store.cfg.providers.filter { $0.kind.transcribes }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Modelo", subtitle: "OpenAI gpt-4o-mini-transcribe, gpt-4o-transcribe ou whisper-1 · Groq whisper-large-v3-turbo · Deepgram nova-3") {
                    TextField("", text: $store.cfg.sttModel).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            SectionTitle("Modelo de texto (modos com IA)")
            Card {
                Row(title: "Provedor") {
                    Picker("", selection: $store.cfg.llmProvider) {
                        ForEach(store.cfg.providers.filter { $0.kind.writes }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Modelo", subtitle: "OpenAI gpt-5.4-mini · Anthropic claude-haiku-5-5 · Gemini gemini-3.5-flash-lite · Groq llama-3.3-70b-versatile") {
                    TextField("", text: $store.cfg.llmModel).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            HStack {
                SectionTitle("Provedores e chaves de API")
                Spacer()
                Button { store.cfg.providers.append(Provider(name: "Novo provedor", kind: .openai, baseURL: "https://")) } label: {
                    Label("Adicionar provedor", systemImage: "plus")
                }
            }
            ForEach(store.cfg.providers) { p in
                ProviderCard(p: binding(p.id)) { store.cfg.providers.removeAll { $0.id == p.id } }
            }
            Text("As chaves ficam guardadas só no seu Mac, legíveis apenas pelo seu usuário. “Compatível com OpenAI” serve para OpenAI, Groq, Gemini, OpenRouter, xAI, DeepSeek, Mistral, Ollama, LM Studio…")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    func binding(_ id: String) -> Binding<Provider> {
        Binding(get: { store.cfg.providers.first { $0.id == id } ?? Provider(name: "", kind: .openai, baseURL: "") },
                set: { v in if let i = store.cfg.providers.firstIndex(where: { $0.id == id }) { store.cfg.providers[i] = v } })
    }
}

struct ProviderCard: View {
    @Binding var p: Provider
    var onDelete: () -> Void
    @State private var key = ""
    @State private var test = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Nome", text: $p.name).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                Picker("", selection: $p.kind) { ForEach(ProviderKind.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            HStack {
                Text("Endereço").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                TextField("", text: $p.baseURL).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Chave").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                SecureField("", text: $key, prompt: Text("cole aqui a sua chave")).textFieldStyle(.roundedBorder)
                    .onChange(of: key) { _, v in Keys.set(p.id, v.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if !key.isEmpty { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Chave salva") }
                Button("Testar") {
                    test = "Testando…"
                    let p = p
                    Task {
                        do {
                            let m = try await AI.models(p)
                            test = "✓ Funcionou" + (m.isEmpty ? "" : " · \(m.count) modelos: " + m.prefix(12).joined(separator: ", "))
                        } catch { test = "✗ " + error.localizedDescription }
                    }
                }
            }
            if !test.isEmpty {
                Text(test).font(.system(size: 11)).foregroundStyle(test.hasPrefix("✓") ? .green : test.hasPrefix("✗") ? .red : .secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
        .onAppear { key = Keys.get(p.id) }
    }
}

// MARK: - Histórico

struct HistoryPage: View {
    let app: AppDelegate
    @State private var items: [(dir: URL, e: Entry)] = []
    @State private var search = ""
    @State private var open: URL?
    @State private var sound: NSSound?

    var body: some View {
        let shown = search.isEmpty ? items : items.filter { ($0.e.result + " " + $0.e.raw).localizedCaseInsensitiveContains(search) }
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.e.date) }.sorted { $0.key > $1.key }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar no histórico", text: $search).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(.horizontal, 24).frame(height: 44)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.key) { day, list in
                        SectionTitle(dayName(day)).padding(.top, 8)
                        ForEach(list, id: \.dir) { it in card(it.dir, it.e) }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .overlay { if items.isEmpty { Text("Nada gravado ainda").foregroundStyle(.secondary) } }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .historyChanged)) { _ in load() }
    }

    func card(_ dir: URL, _ e: Entry) -> some View {
        let expanded = open == dir
        return VStack(alignment: .leading, spacing: 8) {
            if let err = e.error, e.result.isEmpty {
                Text(err).foregroundStyle(.orange).lineLimit(expanded ? nil : 2)
            } else {
                Text(e.result.isEmpty ? e.raw : e.result).lineLimit(expanded ? nil : 2).textSelection(.enabled)
            }
            if expanded {
                Text([e.date.formatted(date: .omitted, time: .shortened), e.mode, "\(Int(e.duration)) s", e.app ?? "", e.models]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if e.raw != e.result && !e.result.isEmpty {
                    Text("Transcrição original: " + e.raw).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                let hasAudio = FileManager.default.fileExists(atPath: dir.appendingPathComponent(e.audio).path)
                HStack(spacing: 14) {
                    Button { Paster.copy(e.result.isEmpty ? e.raw : e.result) } label: { Label("Copiar", systemImage: "doc.on.doc") }
                    if hasAudio { Button {
                        sound?.stop()
                        sound = NSSound(contentsOf: dir.appendingPathComponent(e.audio), byReference: true)
                        sound?.play()
                    } label: { Label("Ouvir", systemImage: "play") }
                    Button { app.reprocess(dir) } label: { Label("Processar de novo", systemImage: "arrow.clockwise") }
                        .help("Usa o modo atual e mostra o resultado na janela de gravação") } else {
                        Text("Áudio apagado").foregroundStyle(.tertiary)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: { Label("Finder", systemImage: "folder") }
                    Spacer()
                    Button(role: .destructive) { try? FileManager.default.removeItem(at: dir); load() } label: { Label("Apagar", systemImage: "trash") }
                }
                .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture { open = expanded ? nil : dir }
    }

    func dayName(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Hoje" : Calendar.current.isDateInYesterday(d) ? "Ontem" : d.formatted(date: .long, time: .omitted)
    }

    func load() { items = Array(loadHistory().prefix(500)) }
}
