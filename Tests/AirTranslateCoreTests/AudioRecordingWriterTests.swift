import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import AirTranslate

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
}
