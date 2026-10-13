import AppKit
import AVFoundation
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.run(); exit(0) }
        // Teste sem interface: Sussurro --transcribe arquivo.wav [--mode id]
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let cfg = Config.load(from: Paths.config)
            let mode = args.firstIndex(of: "--mode").flatMap { j in cfg.modes.first { $0.id == args[j + 1] } } ?? cfg.mode
            Task {
                do {
                    let r = try await AI.run(audio: URL(fileURLWithPath: args[i + 1]), mode: mode, cfg: cfg, ctx: Context())
                    print("BRUTO: \(r.raw)\nFINAL: \(r.result)\nMODELOS: \(r.models)")
                    exit(0)
                } catch { print("ERRO: \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

extension Notification.Name { static let historyChanged = Notification.Name("historyChanged") }

@MainActor
final class Nav: ObservableObject {
    enum Page: String, CaseIterable { case home, modes, vocabulary, config, sound, models, history }
    @Published var page = Page.home { didSet { modeID = nil; advanced = false } }
    @Published var modeID: String?
    @Published var advanced = false
    @Published var sidebar = true
    @Published var capturing = false   // gravando um atalho novo: atalhos globais pausados
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    enum State { case idle, recording, processing }

    let store = Store()
    let nav = Nav()
    let overlay = OverlayModel()
    let mic = MicRecorder()
    let hotkeys = HotKeys()
    let escKey = HotKeys()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var panel: NSPanel!
    var window: NSWindow?
    var state = State.idle { didSet { refreshIcon(); updateEsc() } }
    var lastError: String?
    var launchedAtLogin = false
    var bag = Set<AnyCancellable>()

    var recDir: URL?
    var recMode = Mode.defaults[0]
    var recCtx = Context()
    var recApp: String?
    var meter: Timer?
    var runID = 0
    var startedBy: UInt32 = 0
    var pressedAt = Date.distantPast
    var heldMods = Set<UInt16>()
    var wasMuted: Bool?
    var monitors: [Any] = []

    func applicationWillFinishLaunching(_ n: Notification) {
        // 'oapp' com 'prdt' = 'lgit' => aberto pelo macOS no login (aí não mostra a janela)
        let ev = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = ev?.eventID == 0x6F617070 && ev?.paramDescriptor(forKeyword: 0x70726474)?.enumCodeValue == 0x6C676974
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--rectest") { recTest(); return }
        makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        makePanel()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.installMonitors() }
            }
        }
        installMonitors()
        HotKeys.onEvent = { [weak self] id, down in self?.action(id, down) }
        store.$cfg.receive(on: RunLoop.main).sink { [weak self] _ in self?.applySettings() }.store(in: &bag)
        nav.$capturing.sink { [weak self] on in
            DispatchQueue.main.async { if on { self?.hotkeys.set([]) } else { self?.applySettings() } }
        }.store(in: &bag)
        applySettings()
        cleanOldRecordings()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.cleanOldRecordings() }
        if !launchedAtLogin { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applySettings() {
        let c = store.cfg
        NSApp.appearance = c.theme == "light" ? NSAppearance(named: .aqua) : c.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        applyPolicy()
        if !nav.capturing { hotkeys.set(shortcutList) }
        updateEsc()
        if c.recordOnMenubarClick {
            statusItem.menu = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(statusClicked)
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        } else {
            statusItem.menu = menu
            statusItem.button?.action = nil
        }
        refreshIcon()
    }

    func applyPolicy() {
        NSApp.setActivationPolicy(store.cfg.showInDock || window?.isVisible == true ? .regular : .accessory)
    }

    // MARK: Atalhos

    var shortcutList: [(UInt32, Shortcut)] {
        let c = store.cfg
        return [(1, c.toggleShortcut), (3, c.changeModeShortcut), (4, c.pushToTalkShortcut)]
            + c.modes.enumerated().map { (UInt32(100 + $0.offset), $0.element.shortcut) }
    }

    var active: Bool { state != .idle || panel?.isVisible == true }

    // Esc só fica preso enquanto há gravação ou janela na tela; fora disso volta para os outros apps
    func updateEsc() {
        escKey.set(active && !nav.capturing ? [(UInt32(2), store.cfg.cancelShortcut)] : [])
    }

    func installMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e) } as Any,
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e); return e } as Any,
        ]
    }

    // Atalhos que são uma tecla modificadora sozinha (ex.: ⌥ direito)
    func handle(_ e: NSEvent) {
        guard !nav.capturing else { return }
        if e.type == .keyDown {
            // tecla comum com o modificador-atalho seguro (ex.: ⌥ + letra) = não era ditado
            if state == .recording, let s = shortcutList.first(where: { $0.0 == startedBy })?.1, s.modifierOnly,
               heldMods.contains(s.keyCode), Date().timeIntervalSince(pressedAt) < 1.5 { cancel() }
            return
        }
        guard let mask = Shortcut.sideMask[e.keyCode] else { return }
        let down = e.modifierFlags.rawValue & mask != 0
        guard down != heldMods.contains(e.keyCode) else { return }
        if down { heldMods.insert(e.keyCode) } else { heldMods.remove(e.keyCode) }
        let list = shortcutList + (active ? [(UInt32(2), store.cfg.cancelShortcut)] : [])
        for (id, s) in list where !s.isNone && s.keyCode == e.keyCode { action(id, down) }
    }

    // 1 = gravar/parar (toque liga e desliga; segurar = fala enquanto segura), 2 = cancelar,
    // 3 = trocar modo, 4 = push to talk, 100+n = gravar no modo n
    func action(_ id: UInt32, _ down: Bool) {
        let c = store.cfg
        switch id {
        case 1:
            if down {
                pressedAt = Date()
                if state == .recording { stop() } else if state == .idle { start(c.mode, by: 1) }
            } else if state == .recording && startedBy == 1 && Date().timeIntervalSince(pressedAt) > 0.5 {
                stop()
            }
        case 2: if down { cancel() }
        case 3: if down { cycleMode() }
        case 4:
            if down { if state == .idle { pressedAt = Date(); start(c.mode, by: 4) } } else if state == .recording && startedBy == 4 { stop() }
        default:
            let i = Int(id) - 100
            guard down, c.modes.indices.contains(i) else { return }
            if state == .recording { stop() } else if state == .idle {
                store.cfg.activeMode = c.modes[i].id
                pressedAt = Date()
                start(c.modes[i], by: id)
            }
        }
    }

    @objc func toggleRecording() {
        if state == .recording { stop() } else if state == .idle { start(store.cfg.mode, by: 0) }
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { toggleRecording() }
    }

    // MARK: Gravação

    func start(_ chosen: Mode, by: UInt32) {
        let c = store.cfg
        let front = NSWorkspace.shared.frontmostApplication
        var mode = chosen
        if by < 100, let m = c.modes.first(where: { m in
            m.apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(front?.bundleIdentifier ?? "-")
        }) { mode = m }
        recMode = mode
        recApp = front?.localizedName
        startedBy = by
        recCtx = Context(app: mode.useAppContext ? front?.localizedName : nil,
                         clipboard: mode.useClipboard ? NSPasteboard.general.string(forType: .string) : nil,
                         selection: mode.useSelection ? Paster.selectedText() : nil)
        let dir = newRecordingDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        recDir = dir
        state = .recording
        overlay.mode = mode.name
        overlay.modeIcon = mode.icon
        let stopKey = by >= 100 ? mode.shortcut : by == 4 ? c.pushToTalkShortcut : c.toggleShortcut
        overlay.stopCaps = stopKey.isNone ? c.toggleShortcut.caps : stopKey.caps
        overlay.cancelCaps = c.cancelShortcut.caps
        overlay.begin()
        showPanel()
        playSound("start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.state == .recording { self?.muteIfNeeded() } }
        mic.start(to: dir.appendingPathComponent("audio.wav"), deviceID: c.micID) { [weak self] err in
            guard let self else { return }
            if let err {
                if self.recDir == dir { self.recDir = nil; self.state = .idle }
                try? FileManager.default.removeItem(at: dir)
                self.unmute()
                self.fail(err.localizedDescription)
                return
            }
            guard self.state == .recording, self.recDir == dir else {   // cancelado antes de o microfone abrir
                self.mic.stop { _ in try? FileManager.default.removeItem(at: dir) }
                return
            }
            self.meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.overlay.push(self.mic.level)
            }
        }
    }

    func stop() {
        guard state == .recording, let dir = recDir else { return }
        let duration = mic.duration
        meter?.invalidate()
        unmute()
        playSound("stop")
        recDir = nil
        state = .processing
        overlay.phase = .processing
        showPanel()
        let entry = Entry(mode: recMode.name, duration: duration, app: recApp)
        let mode = recMode, ctx = recCtx
        mic.stop { [weak self] ok in
            guard let self else { return }
            if !ok || duration < 0.3 {   // toque acidental ou microfone nem chegou a abrir
                try? FileManager.default.removeItem(at: dir)
                self.state = .idle
                self.hidePanel()
                return
            }
            self.process(dir: dir, entry: entry, mode: mode, ctx: ctx, paste: true)
        }
    }

    @objc func cancel() {
        switch state {
        case .recording:
            meter?.invalidate()
            unmute()
            let d = recDir
            recDir = nil
            mic.stop { _ in if let d { try? FileManager.default.removeItem(at: d) } }
            state = .idle
        case .processing:
            runID += 1   // o resultado que chegar depois fica só no histórico
            state = .idle
        case .idle: break
        }
        hidePanel()
    }

    func process(dir: URL, entry: Entry, mode: Mode, ctx: Context, paste: Bool) {
        runID += 1
        let my = runID
        state = .processing
        overlay.mode = mode.name
        overlay.modeIcon = mode.icon
        overlay.phase = .processing
        showPanel()
        let cfg = store.cfg
        var pending = entry
        pending.error = "O envio não terminou. Use “Processar de novo”."
        pending.save(dir)
        Task {
            var e = entry
            do {
                let r = try await AI.run(audio: dir.appendingPathComponent(e.audio), mode: mode, cfg: cfg, ctx: ctx)
                (e.raw, e.result, e.models, e.error) = (r.raw, r.result, r.models, nil)
                e.save(dir)
                NotificationCenter.default.post(name: .historyChanged, object: nil)
                guard my == runID else { return }
                state = .idle
                deliver(r.result, paste: paste)
            } catch {
                e.error = error.localizedDescription
                e.save(dir)
                NotificationCenter.default.post(name: .historyChanged, object: nil)
                guard my == runID else { return }
                state = .idle
                fail(error.localizedDescription)
            }
        }
    }

    // Com campo de texto em foco: cola. Sem campo: mostra o texto na janela e deixa no ⌘V.
    func deliver(_ text: String, paste: Bool) {
        let c = store.cfg
        guard !text.isEmpty else { fail("Não ouvi nada nessa gravação."); return }
        if paste && c.pasteResult && Paster.focusedIsEditable() && Paster.paste(text, restore: c.restoreClipboard) {
            hidePanel()
            return
        }
        Paster.copy(text)
        overlay.phase = .result(text)
        showPanel()
        if c.recordingWindow == "mini" { hidePanel(after: 2) }
    }

    func reprocess(_ dir: URL) {
        guard state == .idle, let e = Entry.load(dir) else { return }
        process(dir: dir, entry: e, mode: store.cfg.mode, ctx: Context(), paste: false)
    }

    @objc func transcribeFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        NSApp.activate(ignoringOtherApps: true)
        guard state == .idle, p.runModal() == .OK, let src = p.url else { return }
        let dir = newRecordingDir()
        let mode = store.cfg.mode
        state = .processing
        overlay.mode = mode.name
        overlay.phase = .processing
        showPanel()
        Task {
            do {
                // só o áudio, em m4a: aceita vídeo e fica bem menor (limite de 25 MB da OpenAI)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let asset = AVURLAsset(url: src)
                guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Fail("Não consegui ler o arquivo") }
                try await ex.export(to: dir.appendingPathComponent("audio.m4a"), as: .m4a)
                let duration = try await asset.load(.duration).seconds
                process(dir: dir, entry: Entry(mode: "\(mode.name) · \(src.lastPathComponent)", audio: "audio.m4a", duration: duration),
                        mode: mode, ctx: Context(), paste: false)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                state = .idle
                fail(error.localizedDescription)
            }
        }
    }

    func cycleMode() {
        guard state == .idle, !store.cfg.modes.isEmpty else { return }
        let modes = store.cfg.modes
        let i = ((modes.firstIndex { $0.id == store.cfg.activeMode } ?? -1) + 1) % modes.count
        store.cfg.activeMode = modes[i].id
        overlay.modeList = modes.map(\.name)
        overlay.modeIndex = i
        overlay.mode = modes[i].name
        overlay.modeIcon = modes[i].icon
        overlay.cancelCaps = store.cfg.cancelShortcut.caps
        overlay.phase = .modes
        showPanel()
        hidePanel(after: 1.5, onlyIf: .modes)
    }

    func newRecordingDir() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return Paths.recordings.appendingPathComponent(f.string(from: Date()))
    }

    // Apaga só o áudio das gravações antigas; o meta.json (texto, duração, palavras) fica para as métricas
    func cleanOldRecordings() {
        let days = store.cfg.keepDays
        guard days > 0 else { return }
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        for d in (try? fm.contentsOfDirectory(at: Paths.recordings, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let e = Entry.load(d)
            let date = e?.date ?? (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            guard date < limit else { continue }
            if e == nil { try? fm.removeItem(at: d); continue }   // sobra de gravação sem dados
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != "meta.json" {
                try? fm.removeItem(at: f)
            }
        }
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }

    func fail(_ msg: String) {
        lastError = msg
        playSound("error")
        overlay.phase = .error(msg)
        showPanel()
        hidePanel(after: 6, onlyIf: .error(msg))
    }

    func playSound(_ kind: String) {
        let c = store.cfg
        guard c.soundStyle != "off" else { return }
        let names = c.soundStyle == "simple" ? ["start": "Tink", "stop": "Pop", "error": "Basso"] : ["start": "Purr", "stop": "Bottle", "error": "Sosumi"]
        guard let s = NSSound(named: names[kind]!)?.copy() as? NSSound else { return }
        s.volume = Float(c.soundVolume)
        s.play()
    }

    func muteIfNeeded() {
        guard store.cfg.muteWhileRecording, wasMuted == nil else { return }
        wasMuted = appleScript("output muted of (get volume settings)") == "true"
        if wasMuted == false { _ = appleScript("set volume with output muted") }
    }

    func unmute() {
        if wasMuted == false { _ = appleScript("set volume without output muted") }
        wasMuted = nil
    }

    func appleScript(_ s: String) -> String? {
        var err: NSDictionary?
        return NSAppleScript(source: s)?.executeAndReturnError(&err).stringValue
    }

    // MARK: Janela de gravação

    func makePanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 429, height: 122), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver   // acima de qualquer janela, inclusive outros painéis flutuantes
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.onStop = { [weak self] in self?.stop() }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.onClose = { [weak self] in self?.hidePanel() }
        panel.contentView = NSHostingView(rootView: RecorderView(m: overlay))
        if !panel.setFrameUsingName("recorder"), let s = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - 214, y: s.visibleFrame.minY + 90))
        }
        panel.setFrameAutosaveName("recorder")
    }

    func showPanel() {
        let c = store.cfg
        guard c.recordingWindow != "none" else { return }
        overlay.style = c.recordingWindow
        var size = c.recordingWindow == "mini" ? NSSize(width: 200, height: 44) : NSSize(width: 429, height: 122)
        if c.recordingWindow != "mini" {
            switch overlay.phase {
            case .result(let t):
                let h = (t as NSString).boundingRect(with: NSSize(width: 429 - 56, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium)]).height
                size.height = min(440, max(122, ceil(h) + 36 + 54))
            case .modes: size.height = CGFloat(overlay.modeList.count) * 28 + 20 + 54
            case .error: size.height = 150
            default: break
            }
        }
        var f = panel.frame
        f.origin.x = f.midX - size.width / 2
        f.size = size
        // sempre na tela onde está o mouse e inteira dentro dela (a posição salva pode estar em outro monitor/fora da tela)
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let v = s.visibleFrame
            if !v.intersects(f) { f.origin = NSPoint(x: v.midX - size.width / 2, y: v.minY + 90) }
            f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        }
        panel.setFrame(f, display: true)
        panel.orderFrontRegardless()
        updateEsc()
    }

    func hidePanel() {
        panel.orderOut(nil)
        updateEsc()
    }

    func hidePanel(after s: Double, onlyIf phase: OverlayModel.Phase? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, self.state == .idle, phase == nil || self.overlay.phase == phase else { return }
            self.hidePanel()
        }
    }

    // MARK: Barra de menus e janela principal

    func refreshIcon() {
        let name = state == .idle ? "waveform" : state == .recording ? "record.circle.fill" : "ellipsis.circle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Sussurro")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = store.cfg
        let info = state == .idle ? "Atalho: \(cfg.toggleShortcut.label)" : state == .recording ? "Gravando…" : "Processando…"
        menu.addItem(withTitle: info, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: state == .recording ? "Parar gravação" : "Iniciar gravação", action: #selector(toggleRecording), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Modo", action: nil, keyEquivalent: "").isEnabled = false
        for m in cfg.modes {
            let it = menu.addItem(withTitle: m.name, action: #selector(pickMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.id
            it.state = m.id == cfg.activeMode ? .on : .off
            it.indentationLevel = 1
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Transcrever arquivo…", action: #selector(transcribeFile), keyEquivalent: "").target = self
        if let err = lastError {
            let it = menu.addItem(withTitle: "Último erro: \(err.prefix(70))", action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.toolTip = err
        }
        menu.addItem(withTitle: "Abrir Sussurro…", action: #selector(showWindow), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Sair do Sussurro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func pickMode(_ sender: NSMenuItem) { store.cfg.activeMode = sender.representedObject as! String }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Sussurro"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.minSize = NSSize(width: 760, height: 500)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: MainView(store: store, nav: nav, app: self))
            w.setFrameAutosaveName("main")
            if !w.setFrameUsingName("main") { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        applyPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func open(_ page: Nav.Page) {
        nav.page = page
        showWindow()
    }

    func windowWillClose(_ n: Notification) {
        DispatchQueue.main.async { self.applyPolicy() }
    }

    // sem menu Editar o ⌘V não funciona nos campos (ex.: colar a chave de API)
    func makeMainMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Ajustes…", action: #selector(showWindow), keyEquivalent: ",").target = self
        app.addItem(withTitle: "Sair do Sussurro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let win = NSMenu(title: "Janela")
        win.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for m in [app, edit, win] { let it = NSMenuItem(); it.submenu = m; main.addItem(it) }
        NSApp.mainMenu = main
    }

    // Sussurro --rectest: grava 2 s com o microfone escolhido e descreve o arquivo (teste do gravador)
    func recTest() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sussurro-rectest.wav")
        let log = URL(fileURLWithPath: "/tmp/sussurro-rectest.txt")
        try? FileManager.default.removeItem(at: url)
        mic.start(to: url, deviceID: store.cfg.micID) { [self] err in
            if let err { try? "ERRO \(err.localizedDescription)".write(to: log, atomically: true, encoding: .utf8); exit(1) }
            var peak: Float = 0
            let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in peak = max(peak, self.mic.level) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let dur = self.mic.duration
                t.invalidate()
                self.mic.stop { ok in
                    let f = try? AVAudioFile(forReading: url)
                    let d = f.map { "\($0.fileFormat.sampleRate) Hz, \($0.fileFormat.channelCount) canal, \($0.length) amostras" } ?? "sem arquivo"
                    try? "ok=\(ok) duração=\(dur) pico=\(peak) \(d) \(MicRecorder.name(self.store.cfg.micID))".write(to: log, atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
        }
    }
}

// MARK: - Área de transferência, campo em foco e colar

enum Paster {
    static func focused() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // apps Electron expõem os campos
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    static func focusedIsEditable() -> Bool {
        guard let el = focused() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role as? String ?? "")
    }

    static func selectedText() -> String? {
        guard let el = focused() else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
              let s = sel as? String, !s.isEmpty else { return nil }
        return s
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // Cola com ⌘V no app em foco. restore = devolve o que estava copiado antes. false = sem Acessibilidade.
    static func paste(_ text: String, restore: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        copy(text)
        let ours = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)  // 9 = V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        if restore && !saved.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pb.changeCount == ours else { return }  // usuário copiou outra coisa nesse meio-tempo
                pb.clearContents()
                pb.writeObjects(saved)
            }
        }
        return true
    }
}

// MARK: - Auto-teste: Sussurro --selftest

enum SelfTest {
    static func run() {
        precondition(TextKit.replace("usei o super whisper hoje", [.init(original: "super whisper", with: "Sussurro")]) == "usei o Sussurro hoje")
        precondition(TextKit.replace("Super Whisper.", [.init(original: "super whisper", with: "R$1")]) == "R$1.")
        precondition(TextKit.replace("superwhisperx", [.init(original: "superwhisper", with: "X")]) == "superwhisperx")
        precondition(TextKit.stripThink("<think>hmm\n</think>\n Olá") == "Olá")
        let m = Mode(name: "t", kind: .custom, prompt: "Traduza: {{user_message}}")
        let p = TextKit.prompt(mode: m, text: "oi", ctx: Context(clipboard: "x"), vocabulary: ["Obras Check"])
        precondition(p.user.hasSuffix("Traduza: oi") && p.user.contains("CLIPBOARD") && p.system.contains("Obras Check"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sussurro-test.json")
        try! Data(#"{"sttModel":"x","hotkey":"rightOption","modes":[{"id":"a","name":"A","kind":"email"}]}"#.utf8).write(to: tmp)
        let c = Config.load(from: tmp)
        precondition(c.sttModel == "x" && c.providers.count == Provider.presets.count)
        precondition(c.modes.count == 1 && c.modes[0].kind == .email && c.modes[0].shortcut.isNone && c.toggleShortcut == .toggle)
        // atalho apagado continua apagado depois de salvar e ler de novo
        var c2 = c
        c2.toggleShortcut = .none
        try! JSONEncoder().encode(c2).write(to: tmp)
        precondition(Config.load(from: tmp).toggleShortcut.isNone)
        precondition(Shortcut.changeMode.caps == ["⌥", "⇧", "K"] && Shortcut.changeMode.carbonMods == 0xA00 && Shortcut.toggle.caps == ["⌥"])
        print("selftest ok")
    }
}
