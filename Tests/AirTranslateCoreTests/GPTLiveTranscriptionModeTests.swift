import Foundation
import Testing
@testable import AirTranslate

private final class GPTLiveTranscriptionRecorder: LiveSpeechTranscriberDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let transcriptSignal = DispatchSemaphore(value: 0)
    private var storedTranscripts: [String] = []
    private var storedErrors: [Error] = []

    var transcripts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTranscripts
    }

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }

    func liveSpeechTranscriber(
        _ transcriber: LiveSpeechTranscriber,
        didRecognize text: String,
        language: LanguageOption,
        confidence: Double
    ) {
        lock.lock()
        storedTranscripts.append(text)
        lock.unlock()
        transcriptSignal.signal()
    }

    func liveSpeechTranscriber(_ transcriber: LiveSpeechTranscriber, didFail error: Error) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }

    func waitForNextTranscript() async -> Bool {
        await waitForSignal(transcriptSignal)
    }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + 1) == .success
            )
        }
    }
}

@MainActor
private func waitForSessionStop(_ session: TranslationSessionStore) async {
    for _ in 0..<200 {
        if !session.isRunning && !session.isStarting { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private final class RealtimeTranscriptDeliveryPause: @unchecked Sendable {
    private let didPause = DispatchSemaphore(value: 0)
    private let mayResume = DispatchSemaphore(value: 0)

    func pause() {
        didPause.signal()
        mayResume.wait()
    }

    func waitUntilPaused() async -> Bool {
        await waitForSignal(didPause)
    }

    func resume() {
        mayResume.signal()
    }
}

private actor SuspendedCaptureStop {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didStart = false

    func stop() async {
        didStart = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedTranscriptionFinalizer {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var didStart = false

    func finish() async -> Bool {
        didStart = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@Suite(.serialized)
struct GPTLiveTranscriptionModeTests {
    @Test
    func liveTranscriptionModelHasCanonicalRawValue() {
        #expect(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue == "gpt-live-transcribe")
        #expect(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.isEnabled)
    }

    @Test
    func transcriptionSessionUsesCanonicalLiveTranscriptionContract() throws {
        let url = OpenAIRealtimeTranscriber.transcriptionWebSocketURL
        let queryItems = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let data = try OpenAIRealtimeTranscriber.transcriptionSessionUpdateData(
            language: .korean,
            modelID: OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue,
            audioInputSource: .systemAudio
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        let commitData = try OpenAIRealtimeTranscriber.transcriptionAudioCommitData()
        let commit = try #require(JSONSerialization.jsonObject(with: commitData) as? [String: Any])

        #expect(!queryItems.contains(where: { $0.name == "model" }))
        #expect(queryItems.contains(URLQueryItem(name: "intent", value: "transcription")))
        #expect(session["type"] as? String == "transcription")
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["languages"] as? [String] == ["ko"])
        #expect(transcription["language"] == nil)
        #expect(transcription["delay"] as? String == "high")
        #expect(input["turn_detection"] is NSNull)
        #expect(input["noise_reduction"] is NSNull)
        #expect(commit["type"] as? String == "input_audio_buffer.commit")
    }

    @Test
    func microphoneTranscriptionUsesFarFieldNoiseReduction() throws {
        let data = try OpenAIRealtimeTranscriber.transcriptionSessionUpdateData(
            language: .korean,
            modelID: OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue,
            audioInputSource: .microphone
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let noiseReduction = try #require(input["noise_reduction"] as? [String: Any])

        #expect(noiseReduction["type"] as? String == "far_field")
    }

    @Test
    func mixedLanguageTranscriptionSendsBothLanguageHints() throws {
        let data = try OpenAIRealtimeTranscriber.transcriptionSessionUpdateData(
            languages: [LanguageOption.supported[2], .korean],
            modelID: OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue,
            audioInputSource: .systemAudio
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])

        #expect(transcription["languages"] as? [String] == ["ja", "ko"])
    }

    @Test
    func realtimeTranscriptionCommitsAfterSilenceOrMaximumTurnDuration() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var boundary = RealtimeTranscriptionTurnBoundary()

        let initialSilence = boundary.observe(level: -120, now: startedAt)
        let speechStarted = boundary.observe(level: -20, now: startedAt)
        let silenceStarted = boundary.observe(level: -120, now: startedAt.addingTimeInterval(1))
        let shortSilence = boundary.observe(level: -120, now: startedAt.addingTimeInterval(1.59))
        let silenceCommit = boundary.observe(level: -120, now: startedAt.addingTimeInterval(1.6))
        let nextSpeechStarted = boundary.observe(level: -20, now: startedAt.addingTimeInterval(2))
        let beforeMaximumDuration = boundary.observe(level: -20, now: startedAt.addingTimeInterval(21.9))
        let maximumDurationCommit = boundary.observe(level: -20, now: startedAt.addingTimeInterval(22))

        #expect(!initialSilence)
        #expect(!speechStarted)
        #expect(!silenceStarted)
        #expect(!shortSilence)
        #expect(silenceCommit)
        #expect(!nextSpeechStarted)
        #expect(!beforeMaximumDuration)
        #expect(maximumDurationCommit)
    }

    @Test
    func realtimeTranscriptionForcesCommitAfterFifteenSecondsOfUncommittedAudio() {
        let transcriber = OpenAIRealtimeTranscriber()
        let limit = OpenAIRealtimeTranscriber.maximumUncommittedTranscriptionAudioByteCount

        #expect(
            transcriber.reserveAudioSendSlot(
                audioByteCount: limit - 1,
                marksUncommittedTranscriptionAudio: true
            )
        )
        #expect(!transcriber.isTranscriptionCommitPendingForTesting)
        transcriber.releaseAudioSendSlot()

        #expect(
            transcriber.reserveAudioSendSlot(
                audioByteCount: 1,
                marksUncommittedTranscriptionAudio: true
            )
        )
        #expect(transcriber.isTranscriptionCommitPendingForTesting)
        transcriber.releaseAudioSendSlot()
    }

    @Test
    func translationSessionUsesSupportedTranslationContract() throws {
        let data = try OpenAIRealtimeTranscriber.translationSessionUpdateData(language: .korean)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let output = try #require(audio["output"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])

        #expect(object["type"] as? String == "session.update")
        #expect(transcription["model"] as? String == "gpt-realtime-whisper")
        #expect(input["noise_reduction"] is NSNull)
        #expect(output["language"] as? String == "ko")
        #expect(input["format"] == nil)
        #expect(input["turn_detection"] == nil)
    }

    @Test
    func translationSystemAudioExplicitlyDisablesMicrophoneNoiseReduction() throws {
        let data = try OpenAIRealtimeTranscriber.translationSessionUpdateData(
            language: .korean,
            audioInputSource: .systemAudio
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        #expect(input["noise_reduction"] is NSNull)
        #expect(input["turn_detection"] == nil)
        #expect(input["format"] == nil)
    }

    @Test
    func interleavedTranscriptionItemsKeepIndependentBuffers() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#
        )
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":"Hello "}"#)
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"two","delta":"Good "}"#)
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"Hello one"}"#)
        transcriber.handleEventText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"Good two"}"#)

        #expect(recorder.transcripts.suffix(2) == ["Hello one", "Good two"])
        #expect(!recorder.transcripts.contains(where: { $0.contains("Hello") && $0.contains("Good") }))
    }

    @Test
    func reverseCompletionUsesCommittedItemOrder() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.created","previous_item_id":"one","item":{"id":"assistant","role":"assistant","content":[{"type":"output_text"}]}}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"assistant"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"Second"}"#
        )

        #expect(recorder.transcripts.isEmpty)

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"First"}"#
        )

        #expect(recorder.transcripts == ["First", "Second"])
    }

    @Test
    func completionBeforeLifecycleMetadataWaitsForCausalOrder() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"two","transcript":"Second"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"First"}"#
        )

        #expect(recorder.transcripts == ["First", "Second"])
    }

    @Test
    func orphanTerminalRecoversAfterBoundedMetadataGrace() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"orphan","transcript":"Recovered"}"#
        )
        for index in 0..<8 {
            transcriber.handleEventText(
                #"{"type":"conversation.item.created","item":{"id":"metadata-\#(index)","role":"assistant","content":[{"type":"output_text"}]}}"#
            )
        }

        #expect(recorder.transcripts == ["Recovered"])
        #expect(transcriber.trackedRealtimeTimelineItemCount == 0)
    }

    @Test
    func orphanTerminalRecoversAfterElapsedMetadataGrace() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"orphan","transcript":"Final caption"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        #expect(await recorder.waitForNextTranscript())

        #expect(recorder.transcripts == ["Final caption"])
        #expect(transcriber.trackedRealtimeTimelineItemCount == 0)
    }

    @Test
    func terminalWithMissingPredecessorRecoversAfterElapsedMetadataGrace() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"last","previous_item_id":"missing"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","transcript":"Last caption"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        #expect(await recorder.waitForNextTranscript())

        #expect(recorder.transcripts == ["Last caption"])
        #expect(transcriber.trackedRealtimeTimelineItemCount == 0)
    }

    @Test
    func immediateStopFlushesTerminalWithoutLateDuplicate() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","transcript":"Final caption"}"#
        )
        #expect(recorder.transcripts.isEmpty)

        transcriber.stop()
        #expect(recorder.transcripts == ["Final caption"])

        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.transcripts == ["Final caption"])
    }

    @Test
    func stopAtomicallyClaimsRegisteredTerminalPausedAfterDrain() async {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        let deliveryPause = RealtimeTranscriptDeliveryPause()
        transcriber.delegate = recorder
        transcriber.onRealtimeTranscriptsQueuedForDeliveryForTesting = {
            deliveryPause.pause()
        }
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"last","previous_item_id":null}"#
        )

        let completionTask = Task.detached {
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","transcript":"Registered final"}"#
            )
        }
        let reachedDrain = await deliveryPause.waitUntilPaused()
        transcriber.stop()
        deliveryPause.resume()
        await completionTask.value

        #expect(reachedDrain)
        #expect(recorder.transcripts == ["Registered final"])
    }

    @Test
    func stopAtomicallyClaimsTerminalPausedAfterDelayedDrain() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        let deliveryPause = RealtimeTranscriptDeliveryPause()
        transcriber.delegate = recorder
        transcriber.onRealtimeTranscriptsQueuedForDeliveryForTesting = {
            deliveryPause.pause()
        }
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","transcript":"Delayed final"}"#
        )

        let reachedDrain = await deliveryPause.waitUntilPaused()
        transcriber.stop()
        deliveryPause.resume()
        try await Task.sleep(for: .milliseconds(150))

        #expect(reachedDrain)
        #expect(recorder.transcripts == ["Delayed final"])
    }

    @Test
    func staleCompletionPausedAfterValidationCannotMutateNextGeneration() async {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        let validationPause = RealtimeTranscriptDeliveryPause()
        transcriber.delegate = recorder
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"stale","previous_item_id":null}"#
        )
        let retiredGeneration = transcriber.currentConnectionGeneration
        transcriber.onRealtimeEventValidatedBeforeMutationForTesting = {
            validationPause.pause()
        }

        let staleEventTask = Task.detached {
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"stale","transcript":"Stale final"}"#,
                generation: retiredGeneration
            )
        }
        let reachedValidation = await validationPause.waitUntilPaused()
        transcriber.stop()
        transcriber.onRealtimeEventValidatedBeforeMutationForTesting = nil
        validationPause.resume()
        await staleEventTask.value

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"fresh","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"fresh","transcript":"Fresh final"}"#
        )

        #expect(reachedValidation)
        #expect(recorder.transcripts == ["Fresh final"])
    }

    @Test
    func itemIDLessCompletionQueuedAtomicallyBeforeConcurrentStop() async {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        let mutationPause = RealtimeTranscriptDeliveryPause()
        let stopStarted = DispatchSemaphore(value: 0)
        transcriber.delegate = recorder
        transcriber.onRealtimeTimelineMutationValidatedForTesting = {
            mutationPause.pause()
        }

        let completionTask = Task.detached {
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Itemless final"}"#
            )
        }
        let reachedMutation = await mutationPause.waitUntilPaused()
        let stopTask = Task.detached {
            stopStarted.signal()
            transcriber.stop()
        }
        let didStartStop = await waitForSignal(stopStarted)
        await Task.yield()
        mutationPause.resume()
        await completionTask.value
        await stopTask.value

        #expect(reachedMutation)
        #expect(didStartStop)
        #expect(recorder.transcripts == ["Itemless final"])
    }

    @Test
    func linkedAndUnlinkedItemsUseStableTopologicalOrder() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"child","transcript":"Child"}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"unlinked","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"root","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"child","previous_item_id":"root"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"root","transcript":"Root"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"unlinked","transcript":"Unlinked"}"#
        )

        #expect(recorder.transcripts == ["Unlinked", "Root", "Child"])
    }

    @Test
    func longTimelineKeepsOnlyBoundedPendingState() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        var previousItemID: String?
        for index in 0..<2_000 {
            let itemID = "item-\(index)"
            let previousJSON = previousItemID.map { "\"\($0)\"" } ?? "null"
            transcriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"\#(itemID)","previous_item_id":\#(previousJSON)}"#
            )
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"\#(itemID)","transcript":"Transcript \#(index)"}"#
            )
            previousItemID = itemID
        }

        #expect(recorder.transcripts.count == 2_000)
        #expect(recorder.transcripts.first == "Transcript 0")
        #expect(recorder.transcripts.last == "Transcript 1999")
        #expect(
            transcriber.trackedRealtimeTimelineItemCount
                <= OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount
        )
    }

    @Test
    func pendingTimelineOverflowReportsSanitizedFailureInsteadOfSilentlyDroppingTranscript() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        for index in 0...OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount {
            transcriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"pending-\#(index)","previous_item_id":null}"#
            )
        }

        #expect(recorder.transcripts.isEmpty)
        #expect(recorder.errors.count == 1)
        #expect(recorder.errors.first?.localizedDescription == AppText.openAIInvalidResponse)
        #expect(
            transcriber.trackedRealtimeTimelineItemCount
                <= OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount
        )
    }

    @Test
    func failedItemReleasesItsPerItemThrottleAndKeepsSessionUsable() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"failed","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"failed","delta":"draft"}"#
        )
        #expect(transcriber.realtimeTranscriptionThrottleCount == 1)

        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"failed"}"#
        )
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"next","previous_item_id":"failed"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"next","transcript":"Recovered"}"#
        )

        #expect(transcriber.realtimeTranscriptionThrottleCount == 0)
        #expect(recorder.errors.isEmpty)
        #expect(recorder.transcripts.last == "Recovered")
    }

    @Test
    func stopRejectsEventsFromRetiredConnectionGeneration() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder
        let retiredGeneration = transcriber.currentConnectionGeneration

        transcriber.stop()
        transcriber.handleEventText(
            #"{"type":"error"}"#,
            generation: retiredGeneration
        )

        #expect(recorder.errors.isEmpty)
    }

    @Test
    func completionWithoutDeltaPublishesOnceAndIgnoresDelayedDelta() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"one","previous_item_id":null}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"Final text"}"#
        )
        transcriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":"late secret-bearing delta"}"#
        )
        try await Task.sleep(for: .milliseconds(80))

        #expect(recorder.transcripts == ["Final text"])
    }

    @Test
    func saturatedSendWindowReportsDroppedAudioDuration() {
        let transcriber = OpenAIRealtimeTranscriber()
        let callbackRecorder = RealtimeAudioDegradationRecorder()
        transcriber.onAudioTransportDegraded = { callbackRecorder.record($0) }
        let fortyMillisecondsOfPCM16 = 24_000 * 2 * 40 / 1_000

        for _ in 0..<48 {
            #expect(transcriber.reserveAudioSendSlot(audioByteCount: fortyMillisecondsOfPCM16))
        }
        #expect(!transcriber.reserveAudioSendSlot(audioByteCount: fortyMillisecondsOfPCM16))

        let degradation = transcriber.audioTransportDegradation
        #expect(callbackRecorder.events.count == 1)
        #expect(degradation?.provider == .openAI)
        #expect(degradation?.policy == .dropNewest)
        #expect(degradation?.phase == .sendWindow)
        #expect(degradation?.droppedChunkCount == 1)
        #expect(abs((degradation?.droppedAudioDuration ?? 0) - 0.04) < 0.000_1)
        #expect(degradation?.pendingSendCount == 48)
        #expect(degradation?.pendingSendLimit == 48)

        for _ in 0..<48 {
            transcriber.releaseAudioSendSlot()
        }
    }

    @Test
    func realtimeErrorsDoNotExposeSensitiveDiagnostics() {
        let secret = "test-secret-key"
        let authenticatedURL = URL(
            string: "wss://api.openai.com/v1/realtime?intent=transcription&key=\(secret)"
        )!
        let rawError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSURLErrorFailingURLErrorKey: authenticatedURL,
                NSLocalizedDescriptionKey: "Authorization: Bearer \(secret)"
            ]
        )

        let publicError = OpenAIRealtimeTranscriber.publicConnectionError(from: rawError)

        #expect(publicError.localizedDescription == AppText.openAIRealtimeConnectionFailed)
        #expect(!publicError.localizedDescription.contains(secret))
        #expect(!publicError.localizedDescription.contains("Bearer"))
    }

    @Test
    func serverErrorEventsDoNotExposeProviderMessages() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder

        transcriber.handleEventText(
            #"{"type":"error","error":{"message":"Authorization: Bearer test-secret-key"}}"#
        )

        #expect(recorder.errors.count == 1)
        #expect(recorder.errors.first?.localizedDescription == AppText.openAIRealtimeConnectionFailed)
        #expect(!recorder.errors.contains(where: { $0.localizedDescription.contains("test-secret-key") }))
    }

    @Test
    func serverErrorReleasesOutstandingTranscriptionCommitWaits() {
        let transcriber = OpenAIRealtimeTranscriber()
        transcriber.seedOutstandingTranscriptionCommitForTesting()

        #expect(transcriber.outstandingTranscriptionCommitCountForTesting == 1)
        transcriber.handleEventText(#"{"type":"error"}"#)

        #expect(transcriber.outstandingTranscriptionCommitCountForTesting == 0)
    }

    @Test
    func shortCommitIsBlockedAndCommitEmptyErrorIsRecoverable() {
        let transcriber = OpenAIRealtimeTranscriber()
        let recorder = GPTLiveTranscriptionRecorder()
        transcriber.delegate = recorder
        transcriber.seedOutstandingTranscriptionCommitForTesting()

        #expect(OpenAIRealtimeTranscriber.minimumTranscriptionCommitAudioByteCount == 4_800)
        #expect(!OpenAIRealtimeTranscriber.hasMinimumTranscriptionCommitAudio(4_799))
        #expect(OpenAIRealtimeTranscriber.hasMinimumTranscriptionCommitAudio(4_800))
        transcriber.handleEventText(
            #"{"type":"error","error":{"type":"invalid_request_error","code":"input_audio_buffer_commit_empty"}}"#
        )

        #expect(transcriber.outstandingTranscriptionCommitCountForTesting == 0)
        #expect(recorder.errors.isEmpty)
    }

    @Test
    func recoverableCommitErrorPreservesNewUncommittedAudioAccounting() {
        let transcriber = OpenAIRealtimeTranscriber()
        let audioByteCount = OpenAIRealtimeTranscriber.minimumTranscriptionCommitAudioByteCount
        transcriber.seedOutstandingTranscriptionCommitForTesting()
        #expect(
            transcriber.reserveAudioSendSlot(
                audioByteCount: audioByteCount,
                marksUncommittedTranscriptionAudio: true
            )
        )

        transcriber.handleEventText(
            #"{"type":"error","error":{"code":"input_audio_buffer_commit_empty"}}"#
        )

        #expect(transcriber.outstandingTranscriptionCommitCountForTesting == 0)
        #expect(transcriber.uncommittedTranscriptionAudioByteCountForTesting == audioByteCount)
        transcriber.releaseAudioSendSlot()
    }

    @Test
    @MainActor
    func finalizationUsesFreshAcknowledgementDeadlineAndSurfacesTimeout() async throws {
        let transcriber = OpenAIRealtimeTranscriber()
        transcriber.prepareTranscriptionFinalizationForTesting(pendingSendCount: 1)
        transcriber.seedOutstandingTranscriptionCommitForTesting()

        let providerEvents = Task {
            try? await Task.sleep(for: .milliseconds(80))
            transcriber.releaseAudioSendSlot()
            try? await Task.sleep(for: .milliseconds(100))
            transcriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"final","previous_item_id":null}"#
            )
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"final","transcript":"done"}"#
            )
        }

        let didFinish = await transcriber.finishPendingTranscriptionAudioForTesting(
            phaseTimeout: 0.15
        )
        await providerEvents.value
        #expect(didFinish)
        transcriber.stop()

        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTTranscriptionMode()
        let pipeline = session.activateLiveCallbackPipelineForTesting()
        pipeline.openAITranscriber.onFinishPendingTranscriptionAudioForTesting = { false }

        session.stop()
        await waitForSessionStop(session)

        #expect(session.statusMessage == AppText.gptTranscriptionFinalizationTimedOut)
    }

    @Test
    @MainActor
    func openAIProxyFailureStopsTheMatchingStoreGeneration() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        pipeline.openAITranscriber.handleEventText(#"{"type":"error"}"#)
        await Task.yield()

        #expect(!session.isRunning)
        #expect(session.statusMessage == AppText.openAIRealtimeConnectionFailed)
    }

    @Test
    @MainActor
    func pendingTimelineOverflowStopsTheActiveStoreGeneration() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        for index in 0...OpenAIRealtimeTranscriber.maximumTrackedRealtimeTimelineItemCount {
            pipeline.openAITranscriber.handleEventText(
                #"{"type":"input_audio_buffer.committed","item_id":"pending-\#(index)","previous_item_id":null}"#
            )
        }
        await Task.yield()

        #expect(!session.isRunning)
        #expect(session.statusMessage == AppText.openAIInvalidResponse)
    }

    @Test
    @MainActor
    func itemTranscriptionFailureDoesNotStopButConnectionFailureStillDoes() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        pipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"failed"}"#
        )
        await Task.yield()
        #expect(session.isRunning)

        pipeline.openAITranscriber.handleEventText(#"{"type":"error"}"#)
        await Task.yield()
        #expect(!session.isRunning)
        #expect(session.statusMessage == AppText.openAIRealtimeConnectionFailed)
    }

    @Test
    @MainActor
    func storeStopFlushesLastTerminalBeforeTranscriptTeardown() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        pipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","transcript":"Saved final caption"}"#
        )
        session.stop()
        await waitForSessionStop(session)

        #expect(!session.isRunning)
        #expect(session.lines.contains(where: { $0.sourceText.contains("Saved final caption") }))
    }

    @Test
    @MainActor
    func gptStopStopsCaptureBeforeDrainAndSecondStopAborts() async throws {
        let captureStop = SuspendedCaptureStop()
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTTranscriptionMode()
        _ = session.activateLiveCallbackPipelineForTesting()
        session.setCaptureStopHandlerForTesting { await captureStop.stop() }

        session.stop()
        for _ in 0..<100 where !(await captureStop.didStart) {
            await Task.yield()
        }

        #expect(await captureStop.didStart)
        #expect(session.isRunning)
        #expect(session.statusMessage == AppText.stopping)

        session.stop()

        #expect(!session.isRunning)
        #expect(session.statusMessage == AppText.stopped)
        await captureStop.resume()
    }

    @Test
    @MainActor
    func stoppingStateSpansOnlyDeferredStopFinalization() async throws {
        let captureStop = SuspendedCaptureStop()
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTTranscriptionMode()
        _ = session.activateLiveCallbackPipelineForTesting()
        session.setCaptureStopHandlerForTesting { await captureStop.stop() }

        #expect(!session.isStopping)
        session.stop()
        for _ in 0..<100 where !(await captureStop.didStart) {
            await Task.yield()
        }

        #expect(session.isStopping)
        session.statusMessage = "intermediate status"
        #expect(session.isStopping)

        session.stop()
        #expect(!session.isStopping)
        await captureStop.resume()
    }

    @Test
    @MainActor
    func pausedGPTTranscriptsAreAcceptedOnlyDuringOneShotFlush() async throws {
        let finalizer = SuspendedTranscriptionFinalizer()
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTTranscriptionMode()
        let pipeline = session.activateLiveCallbackPipelineForTesting()
        pipeline.openAITranscriber.onFinishPendingTranscriptionAudioForTesting = {
            await finalizer.finish()
        }

        session.pause()
        for _ in 0..<100 where !(await finalizer.didStart) {
            await Task.yield()
        }
        #expect(session.acceptsPausedGPTTranscriptionFlushForTesting)

        pipeline.openAITranscriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"flush","previous_item_id":null}"#
        )
        pipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"flush","transcript":"accepted flush"}"#
        )
        for _ in 0..<100 where !session.lines.contains(where: { $0.sourceText.contains("accepted flush") }) {
            await Task.yield()
        }
        #expect(session.lines.contains(where: { $0.sourceText.contains("accepted flush") }))

        await finalizer.resume(returning: true)
        for _ in 0..<100 where session.acceptsPausedGPTTranscriptionFlushForTesting {
            await Task.yield()
        }
        #expect(!session.acceptsPausedGPTTranscriptionFlushForTesting)

        pipeline.openAITranscriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"late","previous_item_id":"flush"}"#
        )
        pipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"late","transcript":"rejected late"}"#
        )
        await Task.yield()
        await Task.yield()
        #expect(!session.lines.contains(where: { $0.sourceText.contains("rejected late") }))

        pipeline.openAITranscriber.onFinishPendingTranscriptionAudioForTesting = nil
        session.stop()
        await waitForSessionStop(session)
    }

    @Test
    @MainActor
    func storeStopClaimsRegisteredTerminalPausedAfterDrainBeforeAutosave() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let pipeline = session.activateLiveCallbackPipelineForTesting()
        let transcriber = pipeline.openAITranscriber
        let deliveryPause = RealtimeTranscriptDeliveryPause()
        transcriber.onRealtimeTranscriptsQueuedForDeliveryForTesting = {
            deliveryPause.pause()
        }
        transcriber.handleEventText(
            #"{"type":"input_audio_buffer.committed","item_id":"last","previous_item_id":null}"#
        )

        let completionTask = Task.detached {
            transcriber.handleEventText(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","transcript":"Store final"}"#
            )
        }
        let reachedDrain = await deliveryPause.waitUntilPaused()
        session.stop()
        deliveryPause.resume()
        await completionTask.value
        await waitForSessionStop(session)

        #expect(reachedDrain)
        #expect(!session.isRunning)
        #expect(
            session.lines.filter { $0.sourceText.contains("Store final") }.count == 1
        )
    }

    @Test
    @MainActor
    func storeStopFlushesItemIDLessTerminalBeforeAutosave() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        pipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Itemless store final"}"#
        )
        session.stop()
        await waitForSessionStop(session)

        #expect(
            session.lines.filter { $0.sourceText.contains("Itemless store final") }.count == 1
        )
    }

    @Test
    @MainActor
    func staleProxyRecognitionCannotPolluteRestartedStoreGeneration() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        let firstPipeline = session.activateLiveCallbackPipelineForTesting()
        firstPipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"queued-stale"}"#
        )
        session.stop()
        await waitForSessionStop(session)
        let secondPipeline = session.activateLiveCallbackPipelineForTesting()

        firstPipeline.openAITranscriber.delegate = session
        firstPipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"retired-stale"}"#
        )
        secondPipeline.openAITranscriber.handleEventText(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"fresh"}"#
        )
        await Task.yield()

        #expect(session.lines.contains(where: { $0.sourceText.contains("queued-stale") }))
        #expect(!session.lines.contains(where: { $0.sourceText.contains("retired-stale") }))
        #expect(session.lines.contains(where: { $0.sourceText.contains("fresh") }))
        session.stop()
    }

    @Test
    @MainActor
    func gptTranscriptionTransitionIsSourceOnlyAndRequiresOpenAIKey() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTRealtimeMode()
        session.hasOpenAIAPIKey = false

        session.useGPTTranscriptionMode()

        #expect(session.openAITranscriptionModel == .gptLiveTranscribe)
        #expect(session.openAITranslationModel == .off)
        #expect(session.geminiTranslationModel == .off)
        #expect(session.isUsingOpenAIRealtime)
        #expect(!session.isUsingOpenAIRealtimeTranslation)
        #expect(session.isTranscribeOnlyMode)
        #expect(!session.shouldShowTranslationPane)
        #expect(session.floatingCaptionDisplayMode == .original)
        #expect(!session.isDubbingEnabled)
        #expect(session.startReadinessAssessment().issue == .openAIAPIKeyMissing)
    }

    @Test
    @MainActor
    func mixedLanguageInterpreterInputWaitsForTerminalAndFiltersTargetSentences() async throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.sourceLanguage = LanguageOption.supported[2]
        session.targetLanguage = .korean
        session.useGPTRealtimeMode()
        session.isMixedLanguageInterpreterInputEnabled = true
        let pipeline = session.activateLiveCallbackPipelineForTesting()

        #expect(session.isUsingOpenAIRealtime)
        #expect(!session.isUsingOpenAIRealtimeTranslation)
        #expect(!session.isUsingProviderRealtimeTranslation)
        #expect(!session.isTranscribeOnlyMode)

        session.liveSpeechTranscriber(
            pipeline.transcriber,
            didRecognize: "FDA",
            language: .korean,
            confidence: 0.9
        )
        await Task.yield()
        #expect(session.lines.isEmpty)

        pipeline.openAITranscriber.onTerminalTranscriptReady?(
            "FDA 승인을 검토합니다.",
            .korean,
            0.9
        )
        await Task.yield()
        #expect(session.lines.isEmpty)

        pipeline.openAITranscriber.onTerminalTranscriptReady?(
            "本日の会議を始めます。 오늘 회의를 시작하겠습니다.",
            LanguageOption.supported[2],
            0.9
        )
        await Task.yield()
        #expect(session.lines.first?.sourceText == "本日の会議を始めます。")
    }

    @Test
    @MainActor
    func mixedLanguageInterpreterInputRequiresOnlyAppleTranslationAssets() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTRealtimeMode()
        session.isMixedLanguageInterpreterInputEnabled = true
        session.hasOpenAIAPIKey = true
        session.modelAvailabilityByModelID[IntelligenceModel.appleSystem.id] = ModelAvailability(
            state: .unavailable,
            detail: "Speech unavailable"
        )
        session.modelAvailabilityByModelID[IntelligenceModel.appleOnDevice.id] = ModelAvailability(
            state: .installed,
            detail: "Translation installed"
        )

        #expect(session.startReadinessAssessment().canStart)

        session.modelAvailabilityByModelID[IntelligenceModel.appleOnDevice.id] = ModelAvailability(
            state: .downloadRequired,
            detail: "Translation download needed"
        )
        #expect(session.startReadinessAssessment().issue == .localAssetsDownloadRequired)
    }

    @Test
    @MainActor
    func mixedLanguageInterpreterInputRepairsMatchingPairAndPreservesTarget() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session
        session.useGPTRealtimeMode()
        session.sourceLanguage = .korean
        session.targetLanguage = .korean

        session.isMixedLanguageInterpreterInputEnabled = true

        #expect(session.targetLanguage == .korean)
        #expect(session.sourceLanguage != session.targetLanguage)
        #expect(!session.isTranscribeOnlyMode)

        let repairedSourceLanguage = session.sourceLanguage
        session.useQuickSourceLanguage(.korean)

        #expect(session.sourceLanguage == repairedSourceLanguage)
        #expect(session.targetLanguage == .korean)
    }

    @Test
    @MainActor
    func gptTranslationStillUsesTranslationModelAndWhisperSidecar() throws {
        let fixture = try makeTranscriptionSession()
        defer { cleanup(fixture) }
        let session = fixture.session

        session.useGPTRealtimeMode()

        #expect(session.openAITranslationModel == .gptRealtimeTranslate)
        #expect(session.openAITranscriptionModel == .off)
        #expect(OpenAIRealtimeTranscriptionModel.gptRealtimeWhisper.rawValue == "gpt-realtime-whisper")
    }

    @Test
    @MainActor
    func restorePreservesGPTTranscriptionMode() throws {
        let fixture = try makeTranscriptionSession { defaults in
            defaults.set(IntelligenceModel.appleSpeechOnly.rawValue, forKey: "selectedModelID")
            defaults.set(OpenAIRealtimeTranscriptionModel.gptLiveTranscribe.rawValue, forKey: "openAITranscriptionModelID")
            defaults.set(OpenAIRealtimeTranslationModel.gptRealtimeTranslate.rawValue, forKey: "openAITranslationModelID")
            defaults.set(GeminiTranslationModel.gemini35LiveTranslate.rawValue, forKey: "geminiTranslationModelID")
        }
        defer { cleanup(fixture) }
        let session = fixture.session

        #expect(session.isUsingGPTTranscriptionMode)
        #expect(session.openAITranslationModel == .off)
        #expect(session.geminiTranslationModel == .off)
        #expect(session.selectedModel == .appleSpeechOnly)
    }

    private struct TranscriptionSessionFixture {
        let session: TranslationSessionStore
        let defaults: UserDefaults
        let defaultsSuiteName: String
        let transcriptsDirectoryURL: URL
    }

    @MainActor
    private func makeTranscriptionSession(
        configureDefaults: (UserDefaults) -> Void = { _ in }
    ) throws -> TranscriptionSessionFixture {
        let defaultsSuiteName = "AirTranslateGPTLiveTranscriptionModeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        configureDefaults(defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(defaultsSuiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = TranslationSessionStore(
            modelAvailabilityProvider: { _, _ in [:] },
            settingsDefaults: defaults,
            transcriptsDirectoryURL: directory
        )
        return TranscriptionSessionFixture(
            session: session,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName,
            transcriptsDirectoryURL: directory
        )
    }

    @MainActor
    private func cleanup(_ fixture: TranscriptionSessionFixture) {
        fixture.session.stop()
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.transcriptsDirectoryURL)
    }
}
