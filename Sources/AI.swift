import Foundation
import UniformTypeIdentifiers

struct Fail: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

// Chamadas HTTP aos provedores. Tudo sai direto do Mac para a API escolhida, com a sua chave.
enum AI {
    static func url(_ p: Provider, _ path: String) throws -> URL {
        let base = p.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: base + path), u.scheme != nil else { throw Fail("Endereço inválido em \(p.name): \(p.baseURL)") }
        return u
    }

    // Conexão travada (rede trocou, Mac acordou) só falha no timeout: tenta de novo numa sessão nova, sem reaproveitar a conexão morta.
    static func send(_ r: URLRequest, timeout: TimeInterval = 30) async throws -> [String: Any] {
        var r = r
        r.timeoutInterval = timeout
        var attempt = 0
        let (data, resp): (Data, URLResponse)
        while true {
            let s = URLSession(configuration: .ephemeral)
            defer { s.finishTasksAndInvalidate() }
            do { (data, resp) = try await s.data(for: r); break } catch let e as URLError
                where attempt < 2 && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(e.code) {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt))
            }
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Fail("HTTP \(code): \(String(decoding: data.prefix(500), as: UTF8.self))") }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Fail("Resposta inesperada da API") }
        return j
    }

    static func auth(_ r: inout URLRequest, _ p: Provider) {
        let k = p.key
        switch p.kind {
        case .anthropic:
            r.setValue(k, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepgram: r.setValue("Token \(k)", forHTTPHeaderField: "Authorization")
        case .openai: if !k.isEmpty { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        }
    }

    static func mime(_ f: URL) -> String { UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream" }

    static func transcribe(_ audio: URL, _ p: Provider, model: String, language: String, translate: Bool, vocabulary: [String]) async throws -> String {
        let data = try Data(contentsOf: audio)
        switch p.kind {
        case .anthropic:
            throw Fail("A Anthropic não transcreve áudio. Escolha outro provedor de transcrição em IA.")
        case .deepgram:
            var c = URLComponents(url: try url(p, "/listen"), resolvingAgainstBaseURL: false)!
            var q = [URLQueryItem(name: "model", value: model), .init(name: "smart_format", value: "true")]
            q.append(language.isEmpty ? .init(name: "detect_language", value: "true") : .init(name: "language", value: language))
            q += vocabulary.map { .init(name: "keyterm", value: $0) }
            c.queryItems = q
            var r = URLRequest(url: c.url!)
            r.httpMethod = "POST"
            auth(&r, p)
            r.setValue(mime(audio), forHTTPHeaderField: "Content-Type")
            r.httpBody = data
            let j = try await send(r, timeout: data.count > 2_000_000 ? 300 : 30)
            let ch = (j["results"] as? [String: Any])?["channels"] as? [[String: Any]]
            guard let t = (ch?.first?["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String else { throw Fail("Deepgram não devolveu texto") }
            return t
        case .openai:
            var fields = [("model", model), ("response_format", "json")]
            if !language.isEmpty && !translate { fields.append(("language", language)) }
            if !vocabulary.isEmpty { fields.append(("prompt", vocabulary.joined(separator: ", "))) }
            var r = URLRequest(url: try url(p, translate ? "/audio/translations" : "/audio/transcriptions"))
            r.httpMethod = "POST"
            auth(&r, p)
            let b = "sussurro-\(UUID().uuidString)"
            r.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for (k, v) in fields { body += Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8) }
            body += Data("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: \(mime(audio))\r\n\r\n".utf8)
            body += data
            body += Data("\r\n--\(b)--\r\n".utf8)
            r.httpBody = body
            guard let t = try await send(r, timeout: data.count > 2_000_000 ? 300 : 30)["text"] as? String else { throw Fail("A API não devolveu texto") }
            return t
        }
    }

    static func complete(_ p: Provider, model: String, system: String, user: String) async throws -> String {
        var r: URLRequest
        let body: [String: Any]
        switch p.kind {
        case .deepgram:
            throw Fail("Deepgram só transcreve. Escolha outro provedor para o modelo de texto em IA.")
        case .anthropic:
            r = URLRequest(url: try url(p, "/messages"))
            body = ["model": model, "max_tokens": 8192, "system": system, "messages": [["role": "user", "content": user]]]
        case .openai:
            r = URLRequest(url: try url(p, "/chat/completions"))
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        r.httpMethod = "POST"
        auth(&r, p)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let j = try await send(r, timeout: 90)
        let text: String? = p.kind == .anthropic
            ? (j["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            : ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        guard let text else { throw Fail("A API não devolveu texto") }
        return TextKit.stripThink(text)
    }

    // Testa a chave listando os modelos do provedor
    static func models(_ p: Provider) async throws -> [String] {
        var r = URLRequest(url: try url(p, p.kind == .deepgram ? "/projects" : "/models"))
        auth(&r, p)
        let j = try await send(r)
        return ((j["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    // Áudio -> texto -> (modo com IA) texto final
    static func run(audio: URL, mode: Mode, cfg: Config, ctx: Context) async throws -> (raw: String, result: String, models: String) {
        guard let stt = cfg.provider(cfg.sttProvider) else { throw Fail("Escolha um provedor de transcrição em IA.") }
        let local = stt.baseURL.contains("localhost") || stt.baseURL.contains("127.0.0.1")
        if !local, stt.key.isEmpty { throw Fail("Coloque a chave de \(stt.name) em Ajustes › IA.") }
        let raw = TextKit.replace(try await transcribe(audio, stt, model: cfg.sttModel, language: mode.language,
                                                    translate: mode.translateToEnglish, vocabulary: cfg.terms)
                                   .trimmingCharacters(in: .whitespacesAndNewlines), cfg.replacements)
        var models = "\(stt.name) · \(cfg.sttModel)"
        guard mode.kind != .voice || !mode.prompt.isEmpty, !raw.isEmpty else { return (raw, raw, models) }
        guard let llm = cfg.provider(cfg.llmProvider) else { throw Fail("Escolha um provedor para o modelo de texto em IA.") }
        let pr = TextKit.prompt(mode: mode, text: raw, ctx: ctx, vocabulary: cfg.terms)
        models += " → \(llm.name) · \(cfg.llmModel)"
        return (raw, TextKit.replace(try await complete(llm, model: cfg.llmModel, system: pr.system, user: pr.user), cfg.replacements), models)
    }
}
