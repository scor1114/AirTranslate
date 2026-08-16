import Foundation

package struct RealtimeTranscriptAccumulator {
    package private(set) var text = ""

    private var committedText = ""
    private var currentSegment = ""

    package init() {}

    package mutating func append(_ snapshot: String, languageID: String) {
        let snapshot = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else { return }

        if currentSegment.isEmpty {
            currentSegment = snapshot
        } else if TranscriptTextProcessor.isRevisionOfCurrentPartial(
            current: currentSegment,
            incoming: snapshot
        ) {
            currentSegment = TranscriptTextProcessor.preferredPartialText(
                current: currentSegment,
                incoming: snapshot
            )
        } else {
            committedText = joined(committedText, currentSegment, languageID: languageID)
            currentSegment = snapshot
        }

        text = joined(committedText, currentSegment, languageID: languageID)
    }

    package mutating func reset() {
        self = Self()
    }

    private func joined(_ lhs: String, _ rhs: String, languageID: String) -> String {
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs + rhs }
        guard let last = lhs.last, let first = rhs.first else { return lhs + rhs }

        if ".,!?;:)]}…。，！？；：」』】》）".contains(first)
            || "([{\"‘“「『【《（".contains(last) {
            return lhs + rhs
        }
        if languageID.hasPrefix("ko"),
           !".!?。！？…".contains(last),
           ["습니다", "니다", "어요", "아요", "세요", "군요", "네요", "죠", "지요", "다"].contains(where: lhs.hasSuffix) {
            return lhs + ". " + rhs
        }
        if languageID.hasPrefix("ja") || languageID.hasPrefix("zh") {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }
}
