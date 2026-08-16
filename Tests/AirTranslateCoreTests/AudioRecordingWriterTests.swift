import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import AirTranslate

private final class OneShotRecordingAppendGate: @unchecked Sendable {
    let didBlock = DispatchSemaphore(value: 0)
    private let mayResume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true

    func blockOnce() {
        let blocks = lock.withLock {
            defer { shouldBlock = false }
            return shouldBlock
        }
        guard blocks else { return }
        didBlock.signal()
        mayResume.wait()
    }

    func resume() {
        mayResume.signal()
    }

    func waitUntilBlocked() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [didBlock] in
                continuation.resume(returning: didBlock.wait(timeout: .now() + 1) == .success)
            }
        }
    }
}

@Suite
struct AudioRecordingWriterTests {
    @Test
    func writesPlayableCompressedRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirTranslateRecordingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = AudioRecordingWriter(
            directoryURL: directory,
            inputSource: .microphone,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        try writer.appendPCM16(Data(count: 16_000 * MemoryLayout<Int16>.size), sampleRate: 16_000)
        let fileURL = try #require(writer.finish())

        #expect(fileURL.pathExtension == "m4a")
        #expect((try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)

        var audioFile: AudioFileID?
        #expect(AudioFileOpenURL(fileURL as CFURL, .readPermission, 0, &audioFile) == noErr)
        if let audioFile {
            AudioFileClose(audioFile)
        }
    }

    @Test
    func keepsCompletedAudioAfterALaterBufferFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirTranslateRecordingFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = AudioRecordingWriter(
            directoryURL: directory,
            inputSource: .microphone,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        try writer.appendPCM16(Data(count: 16_000 * MemoryLayout<Int16>.size), sampleRate: 16_000)
        let fileURL = try #require(writer.fileURL)
        let invalidBuffer = try sampleBufferWithoutFormatDescription()

        #expect(writer.append(invalidBuffer) != nil)
        #expect(writer.finish() == fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect((try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
    }

    @Test
    func recordingQueueIsBoundedAndReportsDroppedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirTranslateRecordingQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = AudioRecordingWriter(
            directoryURL: directory,
            inputSource: .microphone,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let gate = OneShotRecordingAppendGate()
        writer.beforeAppendForTesting = { gate.blockOnce() }
        let registry = AudioSamplePipelineRegistry()
        registry.publish(
            generation: 1,
            transcriber: LiveSpeechTranscriber(),
            openAITranscriber: OpenAIRealtimeTranscriber(),
            geminiLiveTranslator: GeminiLiveTranslationService(),
            recordingWriter: writer,
            recordingFailure: { _ in }
        )
        let sampleBuffer = try pcm16SampleBuffer(sampleCount: 160)
        let sampleByteCount = CMSampleBufferGetTotalSampleSize(sampleBuffer)

        registry.append(sampleBuffer, generation: 1)
        #expect(await gate.waitUntilBlocked())
        for _ in 1..<AudioSamplePipelineRegistry.maximumPendingRecordingAppendCount {
            registry.append(sampleBuffer, generation: 1)
        }
        registry.append(sampleBuffer, generation: 1)

        let degradation = try #require(registry.recordingQueueDegradation())
        #expect(degradation.droppedChunkCount == 1)
        #expect(degradation.droppedByteCount == sampleByteCount)
        #expect(degradation.pendingAppendLimit == 32)

        let clearStartedAt = Date()
        let finalization = registry.beginClear()
        #expect(Date().timeIntervalSince(clearStartedAt) < 0.1)
        gate.resume()
        let result = await finalization.value

        #expect(result.fileURL != nil)
        #expect(result.degradation == degradation)
    }

    private func sampleBufferWithoutFormatDescription() throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        #expect(status == noErr)
        return try #require(sampleBuffer)
    }

    private func pcm16SampleBuffer(sampleCount: Int) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        try #require(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &format,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ) == noErr
        )

        let byteCount = sampleCount * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Int16>.size
        var sampleBuffer: CMSampleBuffer?
        try #require(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: sampleCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ) == noErr
        )
        return try #require(sampleBuffer)
    }
}
