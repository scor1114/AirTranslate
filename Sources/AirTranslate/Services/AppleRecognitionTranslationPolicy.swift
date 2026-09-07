import Foundation

struct AppleRecognitionTranslationPolicy: Sendable {
    static let defaultPartialCadence: TimeInterval = 0.30
    static let defaultSmallPartialSilenceFallback: TimeInterval = 0.70
    private static let maxTrackedSegments = 8

    let partialCadence: TimeInterval
    let smallPartialSilenceFallback: TimeInterval

    init(
        partialCadence: TimeInterval = Self.defaultPartialCadence,
        smallPartialSilenceFallback: TimeInterval = Self.defaultSmallPartialSilenceFallback
    ) {
        self.partialCadence = partialCadence
        self.smallPartialSilenceFallback = smallPartialSilenceFallback
    }

    struct State: Equatable, Sendable {
        var lastRequestedAtBySegmentID: [String: Date] = [:]
        var pendingSmallPartialBySegmentID: [String: PendingSmallPartial] = [:]
        var finalizedAudioEndWatermark: Double?
        var finalizedRevisionBySegmentID: [String: Int] = [:]
    }

    struct PendingSmallPartial: Equatable, Sendable {
        let sourceText: String
        let firstSeenAt: Date
    }

    enum Decision: Equatable, Sendable {
        case requestNow(AppleTranslationRequestIdentity)
        case hold(until: Date)
        case ignoreStale
        case unchanged
    }

    func receive(
        sourceText: String,
        lineID: UUID,
        metadata: AppleSpeechRecognitionMetadata?,
        now: Date,
        state: inout State
    ) -> Decision {
        let trimmedSourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceText.isEmpty else { return .unchanged }

        let identity = AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: trimmedSourceText,
            segmentID: metadata?.segmentID,
            revision: metadata?.revision ?? 0,
            isFinal: metadata?.isFinal ?? false
        )

        guard !isStaleRecognition(metadata, state: state) else {
            return .ignoreStale
        }

        if metadata?.isFinal == true {
            markFinal(metadata, state: &state)
            state.pendingSmallPartialBySegmentID[identity.segmentKey] = nil
            state.lastRequestedAtBySegmentID[identity.segmentKey] = now
            pruneTrackedSegments(state: &state)
            return .requestNow(identity)
        }

        if isSmallPartial(trimmedSourceText) {
            return receiveSmallPartial(
                trimmedSourceText,
                identity: identity,
                now: now,
                state: &state
            )
        }

        let lastRequestedAt = state.lastRequestedAtBySegmentID[identity.segmentKey]
        if lastRequestedAt.map({ now.timeIntervalSince($0) < partialCadence }) == true {
            return .hold(until: lastRequestedAt!.addingTimeInterval(partialCadence))
        }

        state.pendingSmallPartialBySegmentID[identity.segmentKey] = nil
        state.lastRequestedAtBySegmentID[identity.segmentKey] = now
        pruneTrackedSegments(state: &state)
        return .requestNow(identity)
    }

    func acceptsRecognition(
        _ metadata: AppleSpeechRecognitionMetadata?,
        state: State
    ) -> Bool {
        !isStaleRecognition(metadata, state: state)
    }

    func flushSmallPartial(
        lineID: UUID,
        metadata: AppleSpeechRecognitionMetadata?,
        now: Date,
        state: inout State
    ) -> Decision {
        let segmentKey = metadata?.segmentID ?? AppleTranslationRequestIdentity.legacySegmentKey
        guard let pending = state.pendingSmallPartialBySegmentID[segmentKey] else {
            return .unchanged
        }

        let dueAt = pending.firstSeenAt.addingTimeInterval(smallPartialSilenceFallback)
        guard now >= dueAt else {
            return .hold(until: dueAt)
        }

        let identity = AppleTranslationRequestIdentity(
            lineID: lineID,
            sourceText: pending.sourceText,
            segmentID: metadata?.segmentID,
            revision: metadata?.revision ?? 0,
            isFinal: false
        )
        state.pendingSmallPartialBySegmentID[segmentKey] = nil
        state.lastRequestedAtBySegmentID[segmentKey] = now
        pruneTrackedSegments(state: &state)
        return .requestNow(identity)
    }

    func acceptsTranslationResult(
        request: AppleTranslationRequestIdentity,
        current: AppleTranslationLineIdentity
    ) -> Bool {
        guard request.lineID == current.lineID else { return false }
        if let requestSegmentID = request.segmentID {
            guard current.segmentID == requestSegmentID else { return false }
        }
        guard current.revision >= request.revision else { return false }
        return Self.isCompatibleLiveSource(
            current: current.sourceText,
            requested: request.sourceText
        )
    }

    private func receiveSmallPartial(
        _ sourceText: String,
        identity: AppleTranslationRequestIdentity,
        now: Date,
        state: inout State
    ) -> Decision {
        if let pending = state.pendingSmallPartialBySegmentID[identity.segmentKey] {
            state.pendingSmallPartialBySegmentID[identity.segmentKey] = PendingSmallPartial(
                sourceText: sourceText,
                firstSeenAt: pending.firstSeenAt
            )
            let dueAt = pending.firstSeenAt.addingTimeInterval(smallPartialSilenceFallback)
            guard now >= dueAt else {
                return .hold(until: dueAt)
            }
            state.pendingSmallPartialBySegmentID[identity.segmentKey] = nil
            state.lastRequestedAtBySegmentID[identity.segmentKey] = now
            pruneTrackedSegments(state: &state)
            return .requestNow(identity)
        }

        let dueAt = now.addingTimeInterval(smallPartialSilenceFallback)
        state.pendingSmallPartialBySegmentID[identity.segmentKey] = PendingSmallPartial(
            sourceText: sourceText,
            firstSeenAt: now
        )
        pruneTrackedSegments(state: &state)
        return .hold(until: dueAt)
    }

    private func isStaleRecognition(
        _ metadata: AppleSpeechRecognitionMetadata?,
        state: State
    ) -> Bool {
        guard let metadata else { return false }

        // 확정 구간은 불변이다. 재전달된 final도 새 발화로 추가하지 않는다.
        if state.finalizedRevisionBySegmentID[metadata.segmentID] != nil {
            return true
        }

        guard let watermark = state.finalizedAudioEndWatermark,
              metadata.hasValidAudioRange,
              metadata.audioEndSeconds <= watermark,
              state.finalizedRevisionBySegmentID[metadata.segmentID] == nil
        else {
            return false
        }

        return true
    }

    private func markFinal(
        _ metadata: AppleSpeechRecognitionMetadata?,
        state: inout State
    ) {
        guard let metadata else { return }
        state.finalizedRevisionBySegmentID[metadata.segmentID] = metadata.revision
        guard metadata.hasValidAudioRange else { return }
        state.finalizedAudioEndWatermark = max(
            state.finalizedAudioEndWatermark ?? metadata.audioEndSeconds,
            metadata.audioEndSeconds
        )
    }

    private func pruneTrackedSegments(state: inout State) {
        prune(&state.lastRequestedAtBySegmentID)
        prune(&state.pendingSmallPartialBySegmentID)
        prune(&state.finalizedRevisionBySegmentID)
    }

    private func prune<Value>(_ values: inout [String: Value]) {
        guard values.count > Self.maxTrackedSegments else { return }
        for key in values.keys.sorted().prefix(values.count - Self.maxTrackedSegments) {
            values[key] = nil
        }
    }

    private func isSmallPartial(_ sourceText: String) -> Bool {
        let tokens = sourceText.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if tokens.count <= 1 {
            let isSingleLatinWord = sourceText.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
            return sourceText.count <= 3 || isShortCJK(sourceText) || (isSingleLatinWord && sourceText.count <= 12)
        }
        return false
    }

    private func isShortCJK(_ sourceText: String) -> Bool {
        let scalars = sourceText.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty, scalars.count <= 2 else { return false }
        return scalars.allSatisfy { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value))
                || (0x3400...0x9FFF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }

    private static func isCompatibleLiveSource(current: String, requested: String) -> Bool {
        let currentText = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedText = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedText.isEmpty else { return currentText.isEmpty }
        if currentText == requestedText || currentText.hasPrefix(requestedText) {
            return true
        }

        let normalizedCurrentText = currentText.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalizedRequestedText = requestedText.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedCurrentText == normalizedRequestedText
            || normalizedCurrentText.hasPrefix(normalizedRequestedText)
    }
}

struct AppleTranslationRequestIdentity: Equatable, Sendable {
    static let legacySegmentKey = "apple:legacy"

    let lineID: UUID
    let sourceText: String
    let segmentID: String?
    let revision: Int
    let isFinal: Bool

    var segmentKey: String {
        segmentID ?? Self.legacySegmentKey
    }
}

struct AppleTranslationLineIdentity: Equatable, Sendable {
    let lineID: UUID
    let sourceText: String
    let segmentID: String?
    let revision: Int
    let isFinal: Bool
}
