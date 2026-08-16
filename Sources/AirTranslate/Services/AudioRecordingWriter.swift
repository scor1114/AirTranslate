import AudioToolbox
import AVFoundation
import Foundation

final class AudioRecordingWriter: @unchecked Sendable {
    private let directoryURL: URL
    private let inputSource: AudioInputSource
    private let startedAt: Date
    private var audioFile: ExtAudioFileRef?
    private(set) var fileURL: URL?
    private var didFail = false
    private var hasWrittenAudio = false
    var didOpenFile: (@Sendable (URL) -> Void)?
    var isPaused = false

    init(directoryURL: URL, inputSource: AudioInputSource, startedAt: Date = Date()) {
        self.directoryURL = directoryURL
        self.inputSource = inputSource
        self.startedAt = startedAt
    }

    deinit {
        finish()
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Error? {
        guard !isPaused, !didFail else { return nil }

        do {
            let audio = try Self.pcm16Audio(from: sampleBuffer)
            try appendPCM16(audio.data, sampleRate: audio.sampleRate)
            return nil
        } catch {
            stopAfterFailure()
            return error
        }
    }

    func appendPCM16(_ data: Data, sampleRate: Double) throws {
        guard !data.isEmpty else { return }
        if audioFile == nil {
            try openFile(sampleRate: sampleRate)
        }
        guard let audioFile else { throw AudioRecordingError.couldNotCreateFile }

        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return noErr }
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(data.count),
                    mData: UnsafeMutableRawPointer(mutating: baseAddress)
                )
            )
            return ExtAudioFileWrite(audioFile, UInt32(data.count / MemoryLayout<Int16>.size), &bufferList)
        }
        try Self.check(status)
        hasWrittenAudio = true
    }

    @discardableResult
    func finish() -> URL? {
        if let audioFile {
            ExtAudioFileDispose(audioFile)
            self.audioFile = nil
        }
        return fileURL
    }

    private func openFile(sampleRate: Double) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = uniqueRecordingURL()
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var file: ExtAudioFileRef?
        try Self.check(
            ExtAudioFileCreateWithURL(
                fileURL as CFURL,
                kAudioFileM4AType,
                &outputFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &file
            )
        )
        guard let file else {
            try? FileManager.default.removeItem(at: fileURL)
            throw AudioRecordingError.couldNotCreateFile
        }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let status = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: fileURL)
            try Self.check(status)
            return
        }

        audioFile = file
        self.fileURL = fileURL
        didOpenFile?(fileURL)
    }

    private func uniqueRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let source = inputSource == .microphone ? "microphone" : "mac-audio"
        let baseName = "\(formatter.string(from: startedAt))_\(source)"
        var candidate = directoryURL.appendingPathComponent("\(baseName).m4a")
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(baseName)_\(suffix).m4a")
            suffix += 1
        }
        return candidate
    }

    private func stopAfterFailure() {
        didFail = true
        let failedURL = finish()
        guard !hasWrittenAudio else { return }
        if let failedURL { try? FileManager.default.removeItem(at: failedURL) }
        fileURL = nil
    }

    private static func pcm16Audio(from sampleBuffer: CMSampleBuffer) throws -> (data: Data, sampleRate: Double) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              streamDescription.pointee.mChannelsPerFrame == 1
        else {
            throw AudioRecordingError.unsupportedInputFormat
        }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard listSize > 0 else { throw AudioRecordingError.unsupportedInputFormat }

        let data = try withUnsafeTemporaryAllocation(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ) { rawList -> Data in
            guard let baseAddress = rawList.baseAddress else {
                throw AudioRecordingError.unsupportedInputFormat
            }
            let audioBufferList = baseAddress.bindMemory(to: AudioBufferList.self, capacity: 1)
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: listSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            try check(status)

            let format = streamDescription.pointee
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if isFloat {
                let sampleCount = buffers.reduce(into: 0) { count, buffer in
                    count += Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                }
                var samples = [Int16]()
                samples.reserveCapacity(sampleCount)
                for buffer in buffers {
                    guard let source = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let sourceSamples = source.bindMemory(to: Float.self, capacity: count)
                    for index in 0..<count {
                        samples.append(
                            Int16(max(-1, min(1, sourceSamples[index])) * Float(Int16.max)).littleEndian
                        )
                    }
                }
                guard !samples.isEmpty else { throw AudioRecordingError.unsupportedInputFormat }
                return samples.withUnsafeBufferPointer { Data(buffer: $0) }
            }

            let isSignedInteger = format.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger != 0
            let isBigEndian = format.mFormatFlags & kLinearPCMFormatFlagIsBigEndian != 0
            guard format.mBitsPerChannel == 16, isSignedInteger, !isBigEndian else {
                throw AudioRecordingError.unsupportedInputFormat
            }

            var pcm16 = Data()
            pcm16.reserveCapacity(buffers.reduce(into: 0) { $0 += Int($1.mDataByteSize) })
            for buffer in buffers {
                guard let source = buffer.mData else { continue }
                pcm16.append(source.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
            }
            guard !pcm16.isEmpty else { throw AudioRecordingError.unsupportedInputFormat }
            return pcm16
        }

        return (data, streamDescription.pointee.mSampleRate)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioRecordingError.osStatus(status) }
    }
}

enum AudioRecordingError: LocalizedError {
    case couldNotCreateFile
    case unsupportedInputFormat
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateFile:
            AppText.localized(english: "Could not create the audio recording file.", korean: "오디오 녹음 파일을 만들 수 없습니다.")
        case .unsupportedInputFormat:
            AppText.localized(english: "The captured audio format cannot be recorded.", korean: "캡처된 오디오 형식을 녹음할 수 없습니다.")
        case .osStatus(let status):
            AppText.localized(
                english: "Audio recording failed (OSStatus \(status)).",
                korean: "오디오 녹음에 실패했습니다(OSStatus \(status))."
            )
        }
    }
}
