import Foundation
import Testing
@testable import AirTranslate

private final class OpenAIRealtimeProxyRecorder: LiveSpeechTranscriberDelegate {
    private(set) var transcriberIDs: [ObjectIdentifier] = []
    private(set) var transcripts: [String] = []
    private(set) var sourceTranscripts: [String] = []
    private(set) var translations: [String] = []

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognizeSourceTranscript text: String,
        confidence: Double
    ) {
        sourceTranscripts.append(text)
    }

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didTranslate text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        translations.append(text)
    }

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        transcriberIDs.append(ObjectIdentifier(transcriber))
        transcripts.append(text)
    }

    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {}
}

@Suite
struct OpenAIRealtimeTranscriberProxyTests {
    @Test
    func translationDeltasPublishWithoutTurnCommitOrCompletion() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = OpenAIRealtimeProxyRecorder()
        transcriber.delegate = recorder
        transcriber.prepareRealtimeTranslationForTesting()
        transcriber.handleEventText(#"{"type":"session.created"}"#)
        transcriber.handleEventText(#"{"type":"session.updated"}"#)
        transcriber.handleEventText(#"{"type":"session.input_transcript.delta","delta":"Good morning."}"#)
        transcriber.handleEventText(#"{"type":"session.output_transcript.delta","delta":"안녕하세요."}"#)

        #expect(recorder.sourceTranscripts == ["Good morning."])
        #expect(recorder.translations == ["안녕하세요."])
        #expect(recorder.transcripts.isEmpty)

        let oldGeneration = transcriber.currentConnectionGeneration
        transcriber.stop()
        transcriber.handleEventText(
            #"{"type":"session.output_transcript.delta","delta":"stale"}"#,
            generation: oldGeneration
        )
        #expect(recorder.translations == ["안녕하세요."])
    }

    @Test
    func completedEventsReuseDelegateProxy() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = OpenAIRealtimeProxyRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"First"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Second"}"#
        )

        #expect(recorder.transcripts == ["First", "Second"])
        #expect(recorder.transcriberIDs.count == 2)
        #expect(Set(recorder.transcriberIDs).count == 1)
    }
}
