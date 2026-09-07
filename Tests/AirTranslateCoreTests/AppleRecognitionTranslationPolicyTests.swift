import CoreMedia
import Foundation
import Testing
@testable import AirTranslate

@Suite
struct AppleRecognitionTranslationPolicyTests {
    private let policy = AppleRecognitionTranslationPolicy(
        partialCadence: 0.30,
        smallPartialSilenceFallback: 0.70
    )

    @Test
    func finalShortUtteranceRequestsImmediately() {
        var state = AppleRecognitionTranslationPolicy.State()
        let lineID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let metadata = metadata(
            text: "Yes",
            isFinal: true,
            start: 1.0,
            end: 1.2,
            revision: 1,
            emittedAt: now
        )

        let decision = policy.receive(
            sourceText: "Yes",
            lineID: lineID,
            metadata: metadata,
            now: now,
            state: &state
        )

        #expect(decision == .requestNow(AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: "Yes",
            segmentID: metadata.segmentID,
            revision: 1,
            isFinal: true
        )))
    }

    @Test
    func singleTokenPartialWaitsForSilenceFallbackInsteadOfImmediateTranslation() {
        var state = AppleRecognitionTranslationPolicy.State()
        let lineID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 200)
        let metadata = metadata(text: "I", isFinal: false, start: 2.0, end: 2.1, revision: 1, emittedAt: now)

        let firstDecision = policy.receive(
            sourceText: "I",
            lineID: lineID,
            metadata: metadata,
            now: now,
            state: &state
        )
        let secondDecision = policy.flushSmallPartial(
            lineID: lineID,
            metadata: metadata,
            now: now.addingTimeInterval(0.69),
            state: &state
        )
        let finalDecision = policy.flushSmallPartial(
            lineID: lineID,
            metadata: metadata,
            now: now.addingTimeInterval(0.70),
            state: &state
        )

        #expect(firstDecision == .hold(until: now.addingTimeInterval(0.70)))
        #expect(secondDecision == .hold(until: now.addingTimeInterval(0.70)))
        #expect(finalDecision == .requestNow(AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: "I",
            segmentID: metadata.segmentID,
            revision: 1,
            isFinal: false
        )))
    }

    @Test
    func meaningfulPartialUsesBoundedCadence() {
        var state = AppleRecognitionTranslationPolicy.State()
        let lineID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 300)
        let first = metadata(text: "I want", isFinal: false, start: 3.0, end: 3.4, revision: 1, emittedAt: now)
        let second = metadata(
            text: "I want this",
            isFinal: false,
            start: 3.0,
            end: 3.8,
            revision: 2,
            emittedAt: now.addingTimeInterval(0.10)
        )
        let third = metadata(
            text: "I want this translated",
            isFinal: false,
            start: 3.0,
            end: 4.2,
            revision: 3,
            emittedAt: now.addingTimeInterval(0.31)
        )

        let firstDecision = policy.receive(sourceText: "I want", lineID: lineID, metadata: first, now: now, state: &state)
        let secondDecision = policy.receive(
            sourceText: "I want this",
            lineID: lineID,
            metadata: second,
            now: now.addingTimeInterval(0.10),
            state: &state
        )
        let thirdDecision = policy.receive(
            sourceText: "I want this translated",
            lineID: lineID,
            metadata: third,
            now: now.addingTimeInterval(0.31),
            state: &state
        )

        #expect(firstDecision == .requestNow(AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: "I want",
            segmentID: first.segmentID,
            revision: 1,
            isFinal: false
        )))
        #expect(secondDecision == .hold(until: now.addingTimeInterval(0.30)))
        #expect(thirdDecision == .requestNow(AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: "I want this translated",
            segmentID: third.segmentID,
            revision: 3,
            isFinal: false
        )))
    }

    @Test
    func finalizedWatermarkRejectsOlderDifferentSegmentRecognition() {
        var state = AppleRecognitionTranslationPolicy.State()
        let lineID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 400)
        let final = metadata(text: "done", isFinal: true, start: 5.0, end: 6.0, revision: 1, emittedAt: now)
        let stale = metadata(text: "old", isFinal: false, start: 4.0, end: 4.8, revision: 1, emittedAt: now)

        _ = policy.receive(sourceText: "done", lineID: lineID, metadata: final, now: now, state: &state)
        let staleDecision = policy.receive(
            sourceText: "old words",
            lineID: lineID,
            metadata: stale,
            now: now.addingTimeInterval(0.1),
            state: &state
        )

        #expect(staleDecision == .ignoreStale)
    }

    @Test
    func slowerPartialTranslationCanStillApplyToLaterFinalSameSegment() {
        let lineID = UUID()
        let request = AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: "I want this",
            segmentID: "apple:en:7000",
            revision: 2,
            isFinal: false
        )
        let current = AppleTranslationLineIdentity(
            lineID: lineID,
            sourceText: "I want this translated.",
            segmentID: "apple:en:7000",
            revision: 4,
            isFinal: true
        )

        #expect(policy.acceptsTranslationResult(request: request, current: current))
    }

    @Test
    func sameTextFromDifferentSegmentDoesNotRewritePreviousLine() {
        let lineID = UUID()
        let request = AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: "hello",
            segmentID: "apple:en:8000",
            revision: 1,
            isFinal: true
        )
        let current = AppleTranslationLineIdentity(
            lineID: lineID,
            sourceText: "hello",
            segmentID: "apple:en:9000",
            revision: 1,
            isFinal: true
        )

        #expect(!policy.acceptsTranslationResult(request: request, current: current))
    }

    @Test
    func metadataBuilderKeepsRevisionsStableWithinAudioStartAndAdvancesAfterFinal() {
        var builder = AppleSpeechRecognitionMetadataBuilder()
        let now = Date(timeIntervalSinceReferenceDate: 500)
        let first = builder.metadata(
            sourceText: "hello",
            language: .english,
            isFinal: false,
            audioRange: range(start: 10.0, end: 10.3),
            emittedAt: now
        )
        let second = builder.metadata(
            sourceText: "hello world",
            language: .english,
            isFinal: true,
            audioRange: range(start: 10.0, end: 10.8),
            emittedAt: now.addingTimeInterval(0.1)
        )

        #expect(first.segmentID == second.segmentID)
        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(second.isFinal)
        #expect(second.audioStartSeconds == 10.0)
        #expect(second.audioEndSeconds == 10.8)
    }

    @Test
    func metadataBuilderKeepsActiveSegmentWhenAppleMovesFinalStartInsidePreviousRange() {
        var builder = AppleSpeechRecognitionMetadataBuilder()
        let now = Date(timeIntervalSinceReferenceDate: 600)
        let partial = builder.metadata(
            sourceText: "I want to book a flight from Se",
            language: .english,
            isFinal: false,
            audioRange: range(start: 17.16, end: 21.24),
            emittedAt: now
        )
        let final = builder.metadata(
            sourceText: "Yes. No. I want to book a flight from Seoul to Tokyo.",
            language: .english,
            isFinal: true,
            audioRange: range(start: 21.24, end: 23.52),
            emittedAt: now.addingTimeInterval(0.1)
        )

        #expect(partial.segmentID == final.segmentID)
        #expect(final.revision == 2)
    }

    @Test
    func metadataBuilderStateStaysBoundedAcrossThousandsOfFinalSegments() {
        var builder = AppleSpeechRecognitionMetadataBuilder()
        let now = Date(timeIntervalSinceReferenceDate: 650)

        for index in 0..<2_000 {
            let metadata = builder.metadata(
                sourceText: "final segment \(index)",
                language: .english,
                isFinal: true,
                audioRange: range(start: Double(index), end: Double(index) + 0.5),
                emittedAt: now.addingTimeInterval(Double(index))
            )
            #expect(metadata.revision == 1)
        }

        #expect(builder.trackedSegmentCount == 1)
    }

    @Test
    func policyStateStaysBoundedAcrossManySegments() {
        var state = AppleRecognitionTranslationPolicy.State()
        let lineID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 700)

        for index in 0..<32 {
            let text = "segment \(index) has enough words"
            _ = policy.receive(
                sourceText: text,
                lineID: lineID,
                metadata: metadata(
                    text: text,
                    isFinal: true,
                    start: Double(index),
                    end: Double(index) + 0.5,
                    revision: 1,
                    emittedAt: now.addingTimeInterval(Double(index))
                ),
                now: now.addingTimeInterval(Double(index)),
                state: &state
            )
        }

        #expect(state.lastRequestedAtBySegmentID.count <= 8)
        #expect(state.finalizedRevisionBySegmentID.count <= 8)
    }

    private func metadata(
        text: String,
        isFinal: Bool,
        start: Double,
        end: Double,
        revision: Int,
        emittedAt: Date
    ) -> AppleSpeechRecognitionMetadata {
        AppleSpeechRecognitionMetadata(
            segmentID: "apple:en:\(Int(start * 1_000))",
            revision: revision,
            isFinal: isFinal,
            audioRange: range(start: start, end: end),
            sourceText: text,
            emittedAt: emittedAt
        )
    }

    private func range(start: Double, end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            end: CMTime(seconds: end, preferredTimescale: 1_000)
        )
    }
}
