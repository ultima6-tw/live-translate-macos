@preconcurrency import Translation
import FoundationModels

/// Translation.framework (primary) + FoundationModels (fallback).
@available(macOS 26.0, iOS 26.0, *)
actor TranslatorManager {

    private var tfSessions: [String: TranslationSession] = [:]
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

    func translate(_ text: String, from src: String, to tgt: String) async -> String {
        let key = "\(src)|\(tgt)"

        // 1. Translation.framework
        if tfSessions[key] == nil {
            let srcLang = Locale.Language(identifier: src)
            let tgtLang = Locale.Language(identifier: tgt)
            let status  = await avail.status(from: srcLang, to: tgtLang)
            if status == .installed {
                tfSessions[key] = TranslationSession(installedSource: srcLang, target: tgtLang)
            }
        }

        if let session = tfSessions[key] {
            do {
                let result = try await session.translate(text)
                return result.targetText.replacingOccurrences(of: "\n", with: " ")
            } catch {
                tfSessions.removeValue(forKey: key)
            }
        }

        // 2. FoundationModels fallback
        guard var session = fmSession else { return "" }
        do {
            return try await fmTranslate(text, src: src, tgt: tgt, session: &session)
        } catch {
            let errStr = "\(error)"
            if errStr.contains("exceededContextWindowSize") {
                let newSession = LanguageModelSession(instructions: Self.fmInstructions)
                fmSession = newSession
                var s = newSession
                return (try? await fmTranslate(text, src: src, tgt: tgt, session: &s)) ?? ""
            }
            return ""
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
