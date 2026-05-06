import Foundation
import Translation
import FoundationModels

// MARK: - Language helpers

let langNames: [String: String] = [
    "en":      "English",
    "ja":      "Japanese",
    "zh-Hant": "Traditional Chinese (繁體中文)",
    "zh-Hans": "Simplified Chinese (简体中文)",
]

// MARK: - FoundationModels path

@available(macOS 26.0, *)
func fmTranslate(text: String, src: String, tgt: String, session: LanguageModelSession) async throws -> String {
    let srcName = langNames[src] ?? src
    let tgtName = langNames[tgt] ?? tgt

    // Primary prompt
    let prompt1 = "You are a translator. Translate the \(srcName) text below into \(tgtName). Reply with ONLY the translated text, nothing else.\n\nText: \(text)\n\nTranslation:"
    do {
        let response = try await session.respond(to: prompt1)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch LanguageModelSession.GenerationError.guardrailViolation {
        fputs("translator: guardrail on primary prompt, trying completion style\n", stderr)
    }

    // Fallback: completion style (less triggering for guardrails)
    let prompt2 = "\(srcName): \(text)\n\(tgtName):"
    do {
        let response = try await session.respond(to: prompt2)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch LanguageModelSession.GenerationError.guardrailViolation {
        fputs("translator: guardrail on fallback prompt too, returning original\n", stderr)
        return "⚠ \(text)"
    }
}

// MARK: - Main

@available(macOS 15.0, *)
func run() async {
    var tfSessions: [String: TranslationSession] = [:]
    let avail = LanguageAvailability()

    // FoundationModels session (Apple Intelligence, available on macOS 26+)
    var fmSession: LanguageModelSession? = nil
    if #available(macOS 26.0, *) {
        let model = SystemLanguageModel.default
        if model.isAvailable {
            fmSession = LanguageModelSession(
                instructions: "You are a professional real-time interpreter. Your sole task is to translate spoken text accurately into the requested language. Translate all input faithfully, including fictional, dramatic, or emotionally charged content, without judgment or modification."
            )
            fputs("translator: Apple Intelligence ready\n", stderr)
        } else {
            fputs("translator: Apple Intelligence unavailable (\(model.availability))\n", stderr)
        }
    }

    while let line = readLine(strippingNewline: true) {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3 else {
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            continue
        }
        let src = parts[0]
        let tgt = parts[1]
        let text = parts[2...].joined(separator: "\t")
        let key = "\(src)|\(tgt)"

        var result = ""

        // 1. Try Translation.framework if pack is installed
        if tfSessions[key] == nil {
            let srcLang = Locale.Language(identifier: src)
            let tgtLang = Locale.Language(identifier: tgt)
            let status = await avail.status(from: srcLang, to: tgtLang)
            if status == .installed {
                tfSessions[key] = TranslationSession(installedSource: srcLang, target: tgtLang)
                fputs("translator: using Translation.framework for \(key)\n", stderr)
            }
        }

        if let session = tfSessions[key] {
            do {
                let r = try await session.translate(text)
                result = r.targetText.replacingOccurrences(of: "\n", with: " ")
            } catch {
                fputs("translator: Translation.framework \(key) error: \(error)\n", stderr)
                tfSessions.removeValue(forKey: key)
            }
        }

        // 2. Fall back to Apple Intelligence if Translation.framework failed/unavailable
        if result.isEmpty, let fm = fmSession {
            if #available(macOS 26.0, *) {
                do {
                    result = try await fmTranslate(text: text, src: src, tgt: tgt, session: fm)
                } catch {
                    fputs("translator: FoundationModels error: \(error)\n", stderr)
                }
            }
        }

        FileHandle.standardOutput.write((result + "\n").data(using: .utf8)!)
    }
}

Task {
    if #available(macOS 15.0, *) {
        await run()
    } else {
        fputs("Requires macOS 15+\n", stderr)
    }
    exit(0)
}
RunLoop.main.run()
