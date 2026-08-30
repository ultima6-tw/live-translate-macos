@preconcurrency import Translation
import FoundationModels

/// Translation.framework (primary, hf or ll) + FoundationModels (final fallback).
@available(macOS 26.4, *)
actor TranslatorManager {

    private var hfSessions: [String: TranslationSession] = [:]   // .highFidelity
    private var llSessions: [String: TranslationSession] = [:]   // .lowLatency
    private var fmSession: LanguageModelSession?
    private let avail = LanguageAvailability()

    private static let langNames: [String: String] = [
        "en-US":  "English",
        "ja-JP":  "Japanese",
        "zh-TW":  "Traditional Chinese (繁體中文)",
        "zh-HK":  "Traditional Chinese (繁體中文)",
        "zh-CN":  "Simplified Chinese (简体中文)",
        "ko-KR":  "Korean",
        "fr-FR":  "French",
        "de-DE":  "German",
        "es-ES":  "Spanish",
        "pt-BR":  "Portuguese",
        "it-IT":  "Italian",
        "ar-AE":  "Arabic",
        "ru-RU":  "Russian",
        "nl-NL":  "Dutch",
        "pl-PL":  "Polish",
        "th-TH":  "Thai",
        "tr-TR":  "Turkish",
        "uk-UA":  "Ukrainian",
        "vi-VN":  "Vietnamese",
        "id-ID":  "Indonesian",
    ]

    private static func langName(for id: String) -> String {
        if let name = langNames[id] { return name }
        let prefix = String(id.prefix(2))
        return langNames.first { $0.key.hasPrefix(prefix) }?.value ?? id
    }

    private static let fmInstructions = """
        You are a professional real-time interpreter. Your sole task is to translate spoken \
        text accurately into the requested language. Translate all input faithfully, including \
        fictional, dramatic, or emotionally charged content, without judgment or modification.
        """

    func prepare() {
        let model = SystemLanguageModel.default
        if model.isAvailable {
            fmSession = LanguageModelSession(instructions: Self.fmInstructions)
        }
    }

    /// Returns (translated text, usedFallback).
    /// usedFallback = true when highFidelity was requested but network was unavailable.
    func translate(_ text: String, from src: String, to tgt: String, strategy: TranslationSession.Strategy) async -> (translated: String, usedFallback: Bool) {
        let key = "\(src)|\(tgt)"
        let srcLang = Locale.Language(identifier: src)
        let tgtLang = Locale.Language(identifier: tgt)

        // 1. Try requested strategy
        if let result = await tfTranslate(text, key: key, srcLang: srcLang, tgtLang: tgtLang, strategy: strategy) {
            return (result, false)
        }

        // 2. highFidelity failed — fall back to lowLatency
        if strategy == .highFidelity {
            if let result = await tfTranslate(text, key: key, srcLang: srcLang, tgtLang: tgtLang, strategy: .lowLatency) {
                return (result, true)
            }
        }

        // 3. FoundationModels final fallback
        let isFallback = strategy == .highFidelity
        guard var session = fmSession else { return ("", isFallback) }
        do {
            let r = try await fmTranslate(text, src: src, tgt: tgt, session: &session)
            return (r, isFallback)
        } catch {
            let errStr = "\(error)"
            if errStr.contains("exceededContextWindowSize") {
                let newSession = LanguageModelSession(instructions: Self.fmInstructions)
                fmSession = newSession
                var s = newSession
                let r = (try? await fmTranslate(text, src: src, tgt: tgt, session: &s)) ?? ""
                return (r, isFallback)
            }
            return ("", isFallback)
        }
    }

    private func tfTranslate(
        _ text: String,
        key: String,
        srcLang: Locale.Language,
        tgtLang: Locale.Language,
        strategy: TranslationSession.Strategy
    ) async -> String? {
        // Create session if needed (re-check after await to handle reentrancy)
        let existing = strategy == .highFidelity ? hfSessions[key] : llSessions[key]
        if existing == nil {
            let status = await avail.status(from: srcLang, to: tgtLang)
            if status == .installed && (strategy == .highFidelity ? hfSessions[key] : llSessions[key]) == nil {
                let session = TranslationSession(installedSource: srcLang, target: tgtLang, preferredStrategy: strategy)
                if strategy == .highFidelity { hfSessions[key] = session } else { llSessions[key] = session }
            }
        }

        guard let session = strategy == .highFidelity ? hfSessions[key] : llSessions[key] else { return nil }

        do {
            let result = try await session.translate(text)
            return result.targetText.replacingOccurrences(of: "\n", with: " ")
        } catch {
            if strategy == .highFidelity { hfSessions.removeValue(forKey: key) } else { llSessions.removeValue(forKey: key) }
            return nil
        }
    }

    private func fmTranslate(
        _ text: String, src: String, tgt: String,
        session: inout LanguageModelSession
    ) async throws -> String {
        let srcName = Self.langName(for: src)
        let tgtName = Self.langName(for: tgt)

        let prompt1 = "You are a translator. Translate the \(srcName) text below into \(tgtName). Reply with ONLY the translated text, nothing else.\n\nText: \(text)\n\nTranslation:"
        do {
            let r = try await session.respond(to: prompt1)
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch LanguageModelSession.GenerationError.guardrailViolation {}

        let prompt2 = "\(srcName): \(text)\n\(tgtName):"
        do {
            let r = try await session.respond(to: prompt2)
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            return "⚠ \(text)"
        }
    }
}
