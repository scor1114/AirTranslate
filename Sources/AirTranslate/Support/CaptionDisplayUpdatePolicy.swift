import Foundation

struct CaptionDisplayUpdatePolicy: Sendable {
    static let defaultRewriteHoldDuration: TimeInterval = 0.28

    let rewriteHoldDuration: TimeInterval

    init(rewriteHoldDuration: TimeInterval = Self.defaultRewriteHoldDuration) {
        self.rewriteHoldDuration = rewriteHoldDuration
    }

    struct State: Equatable, Sendable {
        var visibleText = ""
        var pendingRewriteText: String?
        var rewriteHoldUntil: Date?
    }

    enum Decision: Equatable, Sendable {
        case unchanged
        case published(String)
        case held(until: Date)
    }

    func receive(
        _ candidateText: String,
        at now: Date,
        canHoldRewrite: Bool,
        state: inout State
    ) -> Decision {
        if shouldPublishImmediately(candidateText, canHoldRewrite: canHoldRewrite, state: state) {
            return publish(candidateText, state: &state)
        }

        if let rewriteHoldUntil = state.rewriteHoldUntil {
            state.pendingRewriteText = candidateText

            if now >= rewriteHoldUntil {
                return publishPendingRewrite(state: &state) ?? .unchanged
            }

            return .held(until: rewriteHoldUntil)
        }

        let rewriteHoldUntil = now.addingTimeInterval(rewriteHoldDuration)
        state.pendingRewriteText = candidateText
        state.rewriteHoldUntil = rewriteHoldUntil
        return .held(until: rewriteHoldUntil)
    }

    func flushDueRewrite(at now: Date, state: inout State) -> Decision {
        guard let rewriteHoldUntil = state.rewriteHoldUntil else {
            return .unchanged
        }
        // 타이머가 일찍 깨어도 마지막 후보를 버리지 않고 남은 시간을 예약한다.
        guard now >= rewriteHoldUntil else { return .held(until: rewriteHoldUntil) }

        return publishPendingRewrite(state: &state) ?? .unchanged
    }

    func flushLatest(state: inout State) -> Decision {
        publishPendingRewrite(state: &state) ?? .unchanged
    }

    private func shouldPublishImmediately(
        _ candidateText: String,
        canHoldRewrite: Bool,
        state: State
    ) -> Bool {
        !canHoldRewrite
            || state.visibleText.isEmpty
            || candidateText.isEmpty
            || candidateText == state.visibleText
            || candidateText.hasPrefix(state.visibleText)
    }

    private func publish(_ text: String, state: inout State) -> Decision {
        state.pendingRewriteText = nil
        state.rewriteHoldUntil = nil

        guard state.visibleText != text else {
            return .unchanged
        }

        state.visibleText = text
        return .published(text)
    }

    private func publishPendingRewrite(state: inout State) -> Decision? {
        guard let pendingRewriteText = state.pendingRewriteText else {
            state.rewriteHoldUntil = nil
            return nil
        }

        return publish(pendingRewriteText, state: &state)
    }
}
