import Foundation
import Testing
@testable import AirTranslate

@Suite
struct AppleCaptionRolloverTests {
    @Test
    @MainActor
    func rolloverStartsNewLineAfterCommittedTextGrows() async throws {
        let (session, directory, settingsSuiteName) = try makeTranscriptionSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName) }
        let transcriber = LiveSpeechTranscriber()

        let latestSentence = await feedUntilRollover(session: session, transcriber: transcriber)

        #expect(session.lines.count == 2)
        #expect(session.lines[0].isFinal)
        #expect(session.lines[0].sourceText.contains(sentence(0)))
        #expect(!session.lines[0].sourceText.contains(latestSentence))
        #expect(session.lines[1].sourceText.contains(latestSentence))
    }

    @Test
    @MainActor
    func replayOfFinalizedSentenceAfterRolloverIsNotDuplicated() async throws {
        let (session, directory, settingsSuiteName) = try makeTranscriptionSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName) }
        let transcriber = LiveSpeechTranscriber()

        _ = await feedUntilRollover(session: session, transcriber: transcriber)
        let finalizedLineID = session.lines[0].id
        let activeLineText = session.lines[1].sourceText
        let finalizedSentence = session.lines[0].sourceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""

        send(finalizedSentence, session: session, transcriber: transcriber)
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.lines.count == 2)
        #expect(session.lines[1].sourceText == activeLineText)

        let revisedSentence = String(finalizedSentence.dropLast()) + " revised."
        send(revisedSentence, session: session, transcriber: transcriber)
        #expect(await waitUntil { session.lines[0].sourceText.contains(revisedSentence) })

        #expect(session.lines.count == 2)
        #expect(session.lines[0].id == finalizedLineID)
        #expect(session.lines[0].sourceText.contains(revisedSentence))
        #expect(session.lines[1].sourceText == activeLineText)
    }

    @Test
    @MainActor
    func longSilenceRollsOverSmallerBlocks() async throws {
        let (session, directory, settingsSuiteName) = try makeTranscriptionSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName) }
        let transcriber = LiveSpeechTranscriber()
        session.paragraphBreakSilenceInterval = 0.05

        var index = 0
        while session.lines.first?.sourceText.utf16.count ?? 0 < 170 {
            await feed(sentence(index), session: session, transcriber: transcriber)
            index += 1
        }
        try await Task.sleep(for: .milliseconds(80))

        let sentenceAfterSilence = sentence(index)
        await feed(sentenceAfterSilence, session: session, transcriber: transcriber)

        #expect(session.lines.count == 2)
        #expect(session.lines[0].isFinal)
        #expect(session.lines[1].sourceText.contains(sentenceAfterSilence))
    }

    @Test
    @MainActor
    func savedTranscriptContainsAllRolledOverLines() async throws {
        let (session, directory, settingsSuiteName) = try makeTranscriptionSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName) }
        let transcriber = LiveSpeechTranscriber()

        let latestSentence = await feedUntilRollover(session: session, transcriber: transcriber)
        session.stop()
        let savedText = savedTranscriptText(in: directory)

        #expect(savedText.contains(sentence(0)))
        #expect(savedText.contains(latestSentence))
    }

    @Test
    @MainActor
    func perUpdateWorkStaysBoundedAcrossManySentences() async throws {
        let (session, directory, settingsSuiteName) = try makeTranscriptionSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName) }
        let transcriber = LiveSpeechTranscriber()

        for index in 0..<200 {
            await feed(sentence(index), session: session, transcriber: transcriber)
        }

        #expect(session.lines.count > 5)
        #expect((session.lines.last?.sourceText.utf16.count ?? .max) < 1_400)
        #expect(session.lines.dropLast().allSatisfy { $0.isFinal })
    }

    @MainActor
    private func makeTranscriptionSession() throws -> (TranslationSessionStore, URL, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirTranslateAppleRolloverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsSuiteName = "AirTranslateAppleRolloverSettings-\(UUID().uuidString)"
        let settingsDefaults = UserDefaults(suiteName: settingsSuiteName)!
        let session = TranslationSessionStore(
            modelAvailabilityProvider: { _, _ in [:] },
            settingsDefaults: settingsDefaults,
            transcriptsDirectoryURL: directory
        )
        session.useTranscribeOnlyMode()
        session.sourceLanguage = .english
        session.targetLanguage = .korean
        session.sessionDurationMode = .standard
        session.isTranscriptPersistenceEnabled = true
        session.savedTranscriptContentMode = .original
        session.isAppleSourceAutoDetectionEnabled = false
        session.paragraphBreakSilenceInterval = 30
        session.isRunning = true
        return (session, directory, settingsSuiteName)
    }

    @MainActor
    private func feedUntilRollover(
        session: TranslationSessionStore,
        transcriber: LiveSpeechTranscriber
    ) async -> String {
        var index = 0
        while session.lines.count < 2, index < 100 {
            await feed(sentence(index), session: session, transcriber: transcriber)
            index += 1
        }
        #expect(session.lines.count == 2)
        return sentence(index - 1)
    }

    @MainActor
    private func feed(
        _ text: String,
        session: TranslationSessionStore,
        transcriber: LiveSpeechTranscriber
    ) async {
        send(text, session: session, transcriber: transcriber)
        #expect(await waitUntil { session.lines.last?.sourceText.contains(text) == true })
    }

    private func send(
        _ text: String,
        session: TranslationSessionStore,
        transcriber: LiveSpeechTranscriber
    ) {
        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: text,
            language: .english,
            confidence: 0.9
        )
    }

    private func sentence(_ index: Int) -> String {
        "Marker\(index) unique\(index) payload\(index) closes\(index) ending\(index) complete\(index)."
    }

    private func savedTranscriptText(in directory: URL) -> String {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return ""
        }

        return fileURLs
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 0.5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
