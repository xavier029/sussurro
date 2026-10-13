import AppKit
import AVFoundation
import Carbon
import SwiftUI

// MARK: - Atalhos globais de combinação (⌥⇧K etc.). Modificador sozinho é tratado no AppDelegate.

final class HotKeys {
    static var onEvent: ((UInt32, Bool) -> Void)?
    private static var installed = false
    private var refs: [EventHotKeyRef] = []

    static func debug(_ s: String) {
        guard ProcessInfo.processInfo.environment["SUSSURRO_DEBUG"] != nil, let h = FileHandle(forWritingAtPath: "/tmp/sussurro-debug.txt") else { return }
        h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); h.closeFile()
    }

    func set(_ list: [(UInt32, Shortcut)]) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if !Self.installed {
            Self.installed = true
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var hk = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKeys.debug("evento \(hk.id) \(GetEventKind(ev))")
                HotKeys.onEvent?(hk.id, GetEventKind(ev) == UInt32(kEventHotKeyPressed))
                return noErr
            }, 2, &types, nil, nil)
        }
        for (id, s) in list where !s.isNone && !s.modifierOnly {
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(s.keyCode), s.carbonMods, EventHotKeyID(signature: 0x5355_5353, id: id),
                                          GetApplicationEventTarget(), 0, &ref)
            HotKeys.debug("registrar \(id) \(s.caps.joined()) -> \(err)")
            if err == noErr, let ref { refs.append(ref) }
        }
    }
}

// MARK: - Microfone (escolhe o dispositivo; grava WAV 16 kHz mono)

final class MicRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let queue = DispatchQueue(label: "sussurro.mic")
    private var finished: ((Bool) -> Void)?

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    static func name(_ id: String) -> String {
        (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id))?.localizedName ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microfone"
    }

    var level: Float {
        let db = output.connections.first?.audioChannels.first?.averagePowerLevel ?? -100
        return Float(pow(Double(max(0, min(1, (db + 52) / 46))), 2) * 0.95)
    }
    var duration: Double { output.recordedDuration.seconds.isFinite ? output.recordedDuration.seconds : 0 }

    func start(to url: URL, deviceID: String, done: @escaping (Error?) -> Void) {
        queue.async {
            do {
                guard let dev = (deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID)) ?? AVCaptureDevice.default(for: .audio)
                else { throw Fail("Nenhum microfone encontrado.") }
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                let input = try AVCaptureDeviceInput(device: dev)
                guard self.session.canAddInput(input) else { throw Fail("Não consegui usar o microfone \(dev.localizedName).") }
                self.session.addInput(input)
                if self.session.outputs.isEmpty { self.session.addOutput(self.output) }
                self.output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                             AVLinearPCMIsNonInterleaved: false]
                self.session.commitConfiguration()
                self.session.startRunning()
                self.output.startRecording(to: url, outputFileType: .wav, recordingDelegate: self)
                DispatchQueue.main.async { done(nil) }
            } catch {
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    // ok = arquivo gravado
    func stop(_ done: @escaping (Bool) -> Void) {
        queue.async {
            guard self.output.isRecording else { self.session.stopRunning(); DispatchQueue.main.async { done(false) }; return }
            self.finished = done
            self.output.stopRecording()
            self.queue.asyncAfter(deadline: .now() + 4) {   // o AVFoundation às vezes não chama o delegate
                guard let d = self.finished else { return }
                self.finished = nil
                DispatchQueue.main.async { d(true) }
            }
        }
    }

    func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo url: URL, from c: [AVCaptureConnection], error: Error?) {
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        queue.async {
            self.session.stopRunning()
            let done = self.finished
            self.finished = nil
            DispatchQueue.main.async { done?(ok) }
        }
    }
}

// MARK: - Janela de gravação (Clássica / Mini), igual à do Superwhisper

func dyn(_ dark: CGFloat, _ light: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
        NSColor(white: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
    })
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case idle, recording, processing, result(String), error(String), modes }
    @Published var phase = Phase.recording
    @Published var levels = [Float](repeating: 0, count: 96)
    @Published var mode = ""
    @Published var modeIcon = "mic"
    @Published var stopCaps = ["⌥"]
    @Published var cancelCaps = ["esc"]
    @Published var modeList: [String] = []
    @Published var modeIndex = 0
    var style = "classic"
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onClose: () -> Void = {}

    func begin() {
        phase = .recording
        levels = .init(repeating: 0, count: levels.count)
    }
    func push(_ l: Float) {
        levels.removeFirst()
        levels.append(l)
    }
}

struct KeyCaps: View {
    var caps: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, c in
                Text(c).font(.system(size: c.count > 1 ? 11 : 13, weight: .semibold))
                    .padding(.horizontal, c.count > 1 ? 6 : 0)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.14)))
            }
        }
    }
}

struct Waveform: View {
    var levels: [Float]
    var body: some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(levels.count)
            let w = max(1.5, step * 0.45)
            for (i, l) in levels.enumerated() {
                let h = max(2, CGFloat(l) * size.height)
                let r = CGRect(x: CGFloat(i) * step + (step - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(.primary.opacity(0.3 + 0.7 * Double(l))))
            }
        }
    }
}

struct ProcessingBlob: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = Double(i)
                    Ellipse().fill(Color.primary.opacity(0.16 + 0.1 * p))
                        .frame(width: 110 + 50 * sin(t * 1.3 + p * 2), height: 22 + 10 * sin(t * 1.7 + p))
                        .offset(x: 80 * sin(t * 0.8 + p * 2.1))
                }
            }
            .blur(radius: 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RecorderView: View {
    @ObservedObject var m: OverlayModel

    var body: some View {
        if m.style == "mini" { mini } else { classic }
    }

    var classic: some View {
        VStack(spacing: 0) {
            top.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Image(systemName: m.modeIcon).foregroundStyle(.secondary)
                Text(m.mode).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                switch m.phase {
                case .recording:
                    hint("Parar", m.stopCaps, m.onStop)
                    hint("Cancelar", m.cancelCaps, m.onCancel)
                case .processing: hint("Cancelar", m.cancelCaps, m.onCancel)
                case .idle: hint("Fechar", m.cancelCaps, m.onClose)
                default: hint("Fechar", m.cancelCaps, m.onClose)
                }
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dyn(0.16, 0.92)))
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(dyn(0.2, 0.98)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder var top: some View {
        switch m.phase {
        case .idle:
            HStack(spacing: 10) { Text("Iniciar gravação").font(.system(size: 14, weight: .medium)); KeyCaps(caps: m.stopCaps) }
        case .recording:
            Waveform(levels: m.levels).frame(height: 54).padding(.horizontal, 18)
        case .processing:
            ProcessingBlob()
        case .result(let t):
            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    ScrollView {
                        Text(t).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center).textSelection(.enabled)
                            .padding(.horizontal, 28).padding(.vertical, 18)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                }
                Button(action: m.onClose) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).padding(10).help("Fechar")
            }
        case .error(let t):
            Label(t, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
                .multilineTextAlignment(.center).padding(.horizontal, 20).lineLimit(4).textSelection(.enabled)
        case .modes:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(m.modeList.enumerated()), id: \.offset) { i, name in
                    Text(name).font(.system(size: 13.5, weight: i == m.modeIndex ? .semibold : .regular))
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == m.modeIndex ? Color.accentColor.opacity(0.35) : .clear))
                }
            }
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    func hint(_ title: String, _ caps: [String], _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 6) { Text(title); KeyCaps(caps: caps) } }.buttonStyle(.plain).foregroundStyle(.secondary)
    }

    var mini: some View {
        HStack(spacing: 8) {
            switch m.phase {
            case .recording: Waveform(levels: Array(m.levels.suffix(28))).frame(width: 90, height: 18)
            case .processing: ProgressView().controlSize(.small)
            case .result: Image(systemName: "doc.on.clipboard").foregroundStyle(.green); Text("Copiado").font(.system(size: 12, weight: .medium))
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .modes: Text(m.modeList.indices.contains(m.modeIndex) ? m.modeList[m.modeIndex] : "").font(.system(size: 12, weight: .medium))
            case .idle: Image(systemName: "mic")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(dyn(0.12, 0.96)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
