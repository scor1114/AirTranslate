import AudioToolbox
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
}
