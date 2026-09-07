import Foundation
import Testing
@testable import AirTranslate

@Suite
struct CaptionDisplayUpdatePolicyTests {
    private let policy = CaptionDisplayUpdatePolicy(rewriteHoldDuration: 0.28)
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test
    func firstCaptionAndPrefixAppendPublishWithoutHold() {
        var state = CaptionDisplayUpdatePolicy.State()

        #expect(policy.receive("I", at: start, canHoldRewrite: true, state: &state) == .published("I"))
        #expect(state.visibleText == "I")

        let appendedAt = start.addingTimeInterval(0.01)
        #expect(
            policy.receive("I can hear you", at: appendedAt, canHoldRewrite: true, state: &state)
                == .published("I can hear you")
        )
        #expect(state.pendingRewriteText == nil)
        #expect(state.rewriteHoldUntil == nil)
    }

    @Test
    func nonPrefixRewriteIsHeldInsideBoundedWindow() {
        var state = CaptionDisplayUpdatePolicy.State(visibleText: "I")
        let rewriteAt = start.addingTimeInterval(0.02)
        let expectedHoldUntil = rewriteAt.addingTimeInterval(0.28)

        #expect(
            policy.receive("나", at: rewriteAt, canHoldRewrite: true, state: &state)
                == .held(until: expectedHoldUntil)
        )
        #expect(state.visibleText == "I")
        #expect(state.pendingRewriteText == "나")
        #expect(state.rewriteHoldUntil == expectedHoldUntil)

        let earlyFlush = policy.flushDueRewrite(
            at: expectedHoldUntil.addingTimeInterval(-0.001),
            state: &state
        )
        #expect(earlyFlush == .held(until: expectedHoldUntil))
        #expect(state.visibleText == "I")
    }

    @Test
    func heldRewriteKeepsLatestCandidateAndFlushesAtOriginalDeadline() {
        var state = CaptionDisplayUpdatePolicy.State(visibleText: "I")
        let firstRewriteAt = start.addingTimeInterval(0.02)
        let expectedHoldUntil = firstRewriteAt.addingTimeInterval(0.28)

        #expect(
            policy.receive("나", at: firstRewriteAt, canHoldRewrite: true, state: &state)
                == .held(until: expectedHoldUntil)
        )

        #expect(
            policy.receive(
                "나는 전체 문장을 듣고 있어요",
                at: firstRewriteAt.addingTimeInterval(0.18),
                canHoldRewrite: true,
                state: &state
            ) == .held(until: expectedHoldUntil)
        )
        #expect(state.visibleText == "I")
        #expect(state.pendingRewriteText == "나는 전체 문장을 듣고 있어요")

        #expect(
            policy.flushDueRewrite(
                at: expectedHoldUntil.addingTimeInterval(0.001),
                state: &state
            ) == .published("나는 전체 문장을 듣고 있어요")
        )
        #expect(state.visibleText == "나는 전체 문장을 듣고 있어요")
        #expect(state.pendingRewriteText == nil)
        #expect(state.rewriteHoldUntil == nil)
    }

    @Test
    func finalOrStoppedStateFlushesLatestTextImmediately() {
        var state = CaptionDisplayUpdatePolicy.State(visibleText: "I")
        let rewriteAt = start.addingTimeInterval(0.02)

        #expect(
            policy.receive("나", at: rewriteAt, canHoldRewrite: true, state: &state)
                == .held(until: rewriteAt.addingTimeInterval(0.28))
        )

        #expect(
            policy.receive(
                "나는 지금 전체 문장을 듣고 있어요",
                at: rewriteAt.addingTimeInterval(0.04),
                canHoldRewrite: false,
                state: &state
            ) == .published("나는 지금 전체 문장을 듣고 있어요")
        )
        #expect(state.visibleText == "나는 지금 전체 문장을 듣고 있어요")
        #expect(state.pendingRewriteText == nil)
        #expect(state.rewriteHoldUntil == nil)
    }

    @Test
    func candidateReturningToVisibleTextClearsStalePendingRewrite() {
        var state = CaptionDisplayUpdatePolicy.State(visibleText: "I")
        let rewriteAt = start.addingTimeInterval(0.02)

        #expect(
            policy.receive("나", at: rewriteAt, canHoldRewrite: true, state: &state)
                == .held(until: rewriteAt.addingTimeInterval(0.28))
        )

        #expect(
            policy.receive("I", at: rewriteAt.addingTimeInterval(0.03), canHoldRewrite: true, state: &state)
                == .unchanged
        )
        #expect(state.visibleText == "I")
        #expect(state.pendingRewriteText == nil)
        #expect(state.rewriteHoldUntil == nil)
    }
}
