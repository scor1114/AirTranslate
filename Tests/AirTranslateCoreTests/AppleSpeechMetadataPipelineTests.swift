import CoreMedia
import Foundation
import Testing
@testable import AirTranslate

@Suite
struct AppleSpeechMetadataPipelineTests {
    @Test
    @MainActor
    func appleFinalCanReplaceVolatilePartialWithPrependedWords() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let transcriber = LiveSpeechTranscriber()
        let partial = metadata(
            text: "I want to book a flight from Se",
            start: 21.24,
            end: 22.0,
            revision: 1,
            isFinal: false
        )
        let final = metadata(
            text: "Yes. No. I want to book a flight from Seoul to Tokyo.",
            start: 21.24,
            end: 23.52,
            revision: 2,
            isFinal: true
        )

        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: "I want to book a flight from Se",
            language: .english,
            confidence: 0.9,
            metadata: partial
        )
        #expect(await waitUntil { session.lines.last != nil })

        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: "Yes. No. I want to book a flight from Seoul to Tokyo.",
            language: .english,
            confidence: 0.9,
            metadata: final
        )
        await Task.yield()

        #expect(session.lines.count == 1)
        #expect(session.lines[0].sourceText == "Yes. No. I want to book a flight from Seoul to Tokyo.")
        #expect(session.lines[0].isFinal)
    }

    @Test
    @MainActor
    func repeatedFinalTextWithDifferentAudioRangeCreatesAnotherSegment() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let transcriber = LiveSpeechTranscriber()
        let firstText = "I want to book a flight from Seoul to Tokyo."
        let secondText = "I want to book a flight from Seoul to Tokyo."

        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: firstText,
            language: .english,
            confidence: 0.9,
            metadata: metadata(text: firstText, start: 17.16, end: 21.24, revision: 1, isFinal: true)
        )
        await Task.yield()
        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: secondText,
            language: .english,
            confidence: 0.9,
            metadata: metadata(text: secondText, start: 21.24, end: 23.52, revision: 1, isFinal: true)
        )
        await Task.yield()

        #expect(session.lines.count == 2)
        #expect(session.lines[0].sourceText == firstText)
        #expect(session.lines[1].sourceText == secondText)
        #expect(session.lines.allSatisfy { $0.isFinal })
    }

    @Test
    @MainActor
    func staleRecognitionBehindFinalWatermarkDoesNotAppendSourceLine() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let transcriber = LiveSpeechTranscriber()

        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: "newer final sentence",
            language: .english,
            confidence: 0.9,
            metadata: metadata(text: "newer final sentence", start: 10.0, end: 11.0, revision: 1, isFinal: true)
        )
        await Task.yield()
        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: "older stale sentence",
            language: .english,
            confidence: 0.9,
            metadata: metadata(text: "older stale sentence", start: 8.0, end: 9.0, revision: 1, isFinal: false)
        )
        await Task.yield()

        #expect(session.lines.count == 1)
        #expect(session.lines[0].sourceText == "newer final sentence")
    }

    @Test
    @MainActor
    func legacyRecognitionDelegateStillUsesPartialCompatiblePath() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let transcriber = LiveSpeechTranscriber()

        session.liveSpeechTranscriber(
            transcriber,
            didRecognize: "legacy partial",
            language: .english,
            confidence: 0.9
        )
        await Task.yield()

        #expect(session.lines.count == 1)
        #expect(session.lines[0].sourceText == "legacy partial")
        #expect(!session.lines[0].isFinal)
    }

    @Test
    @MainActor
    func metadataPipelineKeepsManyFinalSegments() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let transcriber = LiveSpeechTranscriber()

        for index in 0..<128 {
            let text = "isolated metadata segment \(index)"
            session.liveSpeechTranscriber(
                transcriber,
                didRecognize: text,
                language: .english,
                confidence: 0.9,
                metadata: metadata(
                    text: text,
                    start: Double(index) * 2.0,
                    end: Double(index) * 2.0 + 1.0,
                    revision: 1,
                    isFinal: true
                )
            )
        }
        #expect(await waitUntil(timeout: 10) { session.lines.count == 128 })

        #expect(session.lines.count == 128)
        #expect(session.lines.first?.sourceText == "isolated metadata segment 0")
        #expect(session.lines.last?.sourceText == "isolated metadata segment 127")
        #expect(session.lines.allSatisfy { $0.isFinal })
    }

    @Test
    @MainActor
    func archivePreservesShortAndRepeatedFinalSegmentsAndIgnoresReplay() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.isTranscriptPersistenceEnabled = true
        let texts = ["Yes.", "No.", "I want to book a flight from Seoul to Tokyo.", "I want to book a flight from Seoul to Tokyo."]
        for (index, text) in texts.enumerated() {
            let result = metadata(text: text, start: Double(index), end: Double(index) + 0.9, revision: 1, isFinal: true)
            session.receiveCaptionForTesting(text, metadata: result)
            session.receiveCaptionForTesting(text, metadata: result)
        }
        #expect(session.lines.map(\.sourceText) == texts)
        session.stop()
        let files = try FileManager.default.contentsOfDirectory(at: fixture.transcriptsDirectoryURL, includingPropertiesForKeys: nil)
        let saved = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(saved.contains("Yes."))
        #expect(saved.contains("No."))
        #expect(saved.components(separatedBy: texts[2]).count - 1 == 2)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test
    @MainActor
    func slowerPartialTranslationKeepsFinalCaptionFinal() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let partial = metadata(text: "I want this", start: 0, end: 0.5, revision: 1, isFinal: false)
        session.receiveCaptionForTesting("I want this", metadata: partial)
        let requested = try #require(session.lines.first)
        session.receiveCaptionForTesting("I want this translated.", metadata: metadata(
            text: "I want this translated.", start: 0, end: 1, revision: 2, isFinal: true
        ))
        session.completeAppleTranslationForTesting("이것을 원합니다", requestedLine: requested, metadata: partial)
        #expect(session.lines.first?.isFinal == true)
        #expect(session.lines.first?.sourceText == "I want this translated.")
    }

    @Test
    @MainActor
    func dubbingDistinguishesRepeatedUtterancesFromSameSegmentReplay() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let firstID = UUID()
        let secondID = UUID()
        let text = "서울에서 도쿄까지 항공편을 예약하고 싶습니다."
        #expect(fixture.session.unspokenAppleTextForTesting(text, lineID: firstID) == text)
        #expect(fixture.session.unspokenAppleTextForTesting(text, lineID: firstID) == nil)
        #expect(fixture.session.unspokenAppleTextForTesting(text, lineID: secondID) == text)
    }

    private struct TranscriptionSessionFixture {
        let session: TranslationSessionStore
        let defaults: UserDefaults
        let defaultsSuiteName: String
        let transcriptsDirectoryURL: URL
    }

    @MainActor
    private func makeTranscriptionSession() throws -> TranscriptionSessionFixture {
        let defaultsSuiteName = "AirTranslateAppleSpeechMetadataPipelineTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(defaultsSuiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = TranslationSessionStore(
            modelAvailabilityProvider: { _, _ in [:] },
            settingsDefaults: defaults,
            transcriptsDirectoryURL: directory
        )
        session.useTranscribeOnlyMode()
        session.sourceLanguage = .english
        session.targetLanguage = .korean
        session.isAppleSourceAutoDetectionEnabled = false
        session.paragraphBreakSilenceInterval = 30
        session.isRunning = true
        return TranscriptionSessionFixture(
            session: session,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName,
            transcriptsDirectoryURL: directory
        )
    }

    private func cleanup(_ fixture: TranscriptionSessionFixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.transcriptsDirectoryURL)
    }

    private func metadata(
        text: String,
        start: Double,
        end: Double,
        revision: Int,
        isFinal: Bool
    ) -> AppleSpeechRecognitionMetadata {
        AppleSpeechRecognitionMetadata(
            segmentID: "apple:en:\(Int(start * 1_000))",
            revision: revision,
            isFinal: isFinal,
            audioRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1_000),
                end: CMTime(seconds: end, preferredTimescale: 1_000)
            ),
            sourceText: text,
            emittedAt: Date(timeIntervalSinceReferenceDate: start),
            emittedAtUptime: start
        )
    }
}
