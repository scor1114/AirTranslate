import Foundation

struct SavedTranscript: Identifiable, Equatable {
    let id: String
    var title: String
    var sourceText: String
    var translatedText: String?
    var sourceFileName: String?
    var translationFileName: String?
    var recordingFileName: String?
    var updatedAt: Date

    var isOriginalAndTranslation: Bool {
        translatedText != nil && translationFileName != nil
    }

    var isAudioOnly: Bool {
        sourceFileName == nil && recordingFileName != nil
    }

    init(
        fileName: String,
        sourceText: String,
        updatedAt: Date
    ) {
        self.id = fileName
        self.title = SavedTranscript.title(from: sourceText, fallback: fileName)
        self.sourceText = sourceText
        self.translatedText = nil
        self.sourceFileName = fileName
        self.translationFileName = nil
        self.recordingFileName = nil
        self.updatedAt = updatedAt
    }

    init(
        id: String,
        sourceFileName: String,
        translationFileName: String,
        sourceText: String,
        translatedText: String,
        updatedAt: Date
    ) {
        self.id = id
        self.title = SavedTranscript.title(from: sourceText, fallback: id)
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceFileName = sourceFileName
        self.translationFileName = translationFileName
        self.recordingFileName = nil
        self.updatedAt = updatedAt
    }

    init(recordingFileName: String, updatedAt: Date) {
        self.id = recordingFileName
        self.title = SavedTranscript.title(from: "", fallback: recordingFileName)
        self.sourceText = ""
        self.translatedText = nil
        self.sourceFileName = nil
        self.translationFileName = nil
        self.recordingFileName = recordingFileName
        self.updatedAt = updatedAt
    }

    private static func title(from text: String, fallback: String) -> String {
        let title = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            return URL(fileURLWithPath: fallback).deletingPathExtension().lastPathComponent
        }

        return String(title.prefix(48))
    }
}
