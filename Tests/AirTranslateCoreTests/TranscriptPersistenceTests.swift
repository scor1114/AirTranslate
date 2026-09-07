import Foundation
import Testing
@testable import AirTranslate

@Suite(.serialized)
struct TranscriptPersistenceTests {
    @Test
    @MainActor
    func transcriptPersistenceIsOffByDefaultAndOptInPersists() throws {
        let (session, directory, defaults, suiteName) = try makeSession()
        defer { cleanup(directory: directory, defaults: defaults, suiteName: suiteName) }

        #expect(!session.isTranscriptPersistenceEnabled)

        session.isTranscriptPersistenceEnabled = true
        let restored = TranslationSessionStore(
            modelAvailabilityProvider: { _, _ in [:] },
            settingsDefaults: defaults,
            transcriptsDirectoryURL: directory
        )

        #expect(restored.isTranscriptPersistenceEnabled)
    }

    @Test
    @MainActor
    func stopDoesNotCreateTranscriptFilesWhenPersistenceIsDisabled() async throws {
        let (session, directory, defaults, suiteName) = try makeSession()
        defer { cleanup(directory: directory, defaults: defaults, suiteName: suiteName) }

        await deliverTranscript("Stop must not persist this text.", to: session)
        session.stop()

        #expect(session.lines.last?.sourceText == "Stop must not persist this text.")
        #expect(transcriptFiles(in: directory).isEmpty)
    }

    @Test
    @MainActor
    func quitDoesNotCreateTranscriptFilesWhenPersistenceIsDisabled() async throws {
        let (session, directory, defaults, suiteName) = try makeSession()
        defer { cleanup(directory: directory, defaults: defaults, suiteName: suiteName) }

        await deliverTranscript("Quit must not persist this text.", to: session)
        session.prepareForTermination()

        #expect(session.lines.last?.sourceText == "Quit must not persist this text.")
        #expect(transcriptFiles(in: directory).isEmpty)
    }

    @Test
    @MainActor
    func optInPersistenceStillWritesTheSelectedTranscriptContent() async throws {
        let (session, directory, defaults, suiteName) = try makeSession()
        defer { cleanup(directory: directory, defaults: defaults, suiteName: suiteName) }

        session.isTranscriptPersistenceEnabled = true
        await deliverTranscript("Opt-in persistence writes this text.", to: session)
        session.stop()

        let savedText = transcriptFiles(in: directory)
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(savedText.contains("Opt-in persistence writes this text."))
    }

    @MainActor
    private func makeSession() throws -> (
        TranslationSessionStore,
        URL,
        UserDefaults,
        String
    ) {
        let suiteName = "TranscriptPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirTranslateTranscriptPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = TranslationSessionStore(
            modelAvailabilityProvider: { _, _ in [:] },
            settingsDefaults: defaults,
            transcriptsDirectoryURL: directory
        )
        session.useTranscribeOnlyMode()
        session.sourceLanguage = .english
        session.targetLanguage = .korean
        session.isRunning = true
        return (session, directory, defaults, suiteName)
    }

    @MainActor
    private func deliverTranscript(_ text: String, to session: TranslationSessionStore) async {
        let pipeline = session.activateLiveCallbackPipelineForTesting()
        session.liveSpeechTranscriber(
            pipeline.transcriber,
            didRecognize: text,
            language: .english,
            confidence: 0.9
        )

        for _ in 0..<50 {
            if session.lines.last?.sourceText == text {
                return
            }
            await Task.yield()
        }
    }

    private func transcriptFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "txt" } ?? []
    }

    private func cleanup(directory: URL, defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
