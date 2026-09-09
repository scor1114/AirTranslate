import Foundation
import NaturalLanguage

package enum MixedLanguageUtteranceRouter {
    private enum ScriptFamily: Hashable {
        case han
        case hangul
        case kana
        case latin
    }

    package static func shouldTranslate(
        _ text: String,
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> Bool {
        sourceText(
            from: text,
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID
        ) != nil
    }

    package static func sourceText(
        from text: String,
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> String? {
        let sourceID = normalizedLanguageID(sourceLanguageID)
        let targetID = normalizedLanguageID(targetLanguageID)
        let segments = sentenceSegments(text).filter {
            shouldTranslateSegment($0, sourceID: sourceID, targetID: targetID)
        }
        let separator = ["ja", "zh"].contains(sourceID) ? "" : " "
        let sourceText = segments
            .joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceText.isEmpty ? nil : sourceText
    }

    private static func shouldTranslateSegment(
        _ text: String,
        sourceID: String,
        targetID: String
    ) -> Bool {
        guard sourceID != targetID else { return true }

        if let scriptDecision = scriptDecision(
            for: text,
            sourceID: sourceID,
            targetID: targetID
        ) {
            return scriptDecision
        }
        if sharesScriptFamily(sourceID, targetID), isShortSegment(text) {
            // ponytail: short shared-script speech is ambiguous; retain it to avoid silent loss.
            return true
        }

        guard let sourceLanguage = naturalLanguage(for: sourceID),
              let targetLanguage = naturalLanguage(for: targetID)
        else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [sourceLanguage, targetLanguage]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let targetConfidence = hypotheses[targetLanguage] ?? 0

        return targetConfidence < 0.6
    }

    private static func sentenceSegments(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var segments: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let segment = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(String(segment))
            }
            return true
        }
        return segments.isEmpty ? [text] : segments
    }

    private static func normalizedLanguageID(_ languageID: String) -> String {
        languageID
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? languageID.lowercased()
    }

    private static func scriptDecision(
        for text: String,
        sourceID: String,
        targetID: String
    ) -> Bool? {
        guard let sourceFamilies = scriptFamilies(for: sourceID),
              let targetFamilies = scriptFamilies(for: targetID),
              sourceFamilies.isDisjoint(with: targetFamilies)
        else { return nil }

        let observedFamilies = scriptFamilies(in: text)
        let hasSourceScript = !observedFamilies.isDisjoint(with: sourceFamilies)
        let hasTargetScript = !observedFamilies.isDisjoint(with: targetFamilies)
        if hasSourceScript { return true }
        if hasTargetScript { return false }
        return nil
    }

    private static func sharesScriptFamily(_ firstLanguageID: String, _ secondLanguageID: String) -> Bool {
        guard let firstFamilies = scriptFamilies(for: firstLanguageID),
              let secondFamilies = scriptFamilies(for: secondLanguageID)
        else { return false }
        return !firstFamilies.isDisjoint(with: secondFamilies)
    }

    private static func isShortSegment(_ text: String) -> Bool {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var wordCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            wordCount += 1
            return wordCount <= 2
        }
        return wordCount <= 2
    }

    private static func scriptFamilies(in text: String) -> Set<ScriptFamily> {
        var families = Set<ScriptFamily>()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                families.insert(.latin)
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                families.insert(.hangul)
            case 0x3040...0x30FF, 0xFF66...0xFF9D:
                families.insert(.kana)
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                families.insert(.han)
            default:
                continue
            }
        }
        return families
    }

    private static func scriptFamilies(for languageID: String) -> Set<ScriptFamily>? {
        switch languageID {
        case "ko": [.hangul]
        case "ja": [.han, .kana]
        case "zh": [.han]
        case "en", "es", "fr", "de": [.latin]
        default: nil
        }
    }

    private static func naturalLanguage(for languageID: String) -> NLLanguage? {
        switch languageID {
        case "en": .english
        case "ko": .korean
        case "ja": .japanese
        case "zh": .simplifiedChinese
        case "es": .spanish
        case "fr": .french
        case "de": .german
        default: nil
        }
    }
}
