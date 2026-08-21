import AirTranslateCore
import Testing

struct MixedLanguageUtteranceRouterTests {
    @Test
    func routesOnlyConfidentTargetLanguageSpeechOutOfTranslation() {
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "本日の議題をご説明します。",
            sourceLanguageID: "ja-JP",
            targetLanguageID: "ko-KR"
        ))
        #expect(!MixedLanguageUtteranceRouter.shouldTranslate(
            "오늘 회의 안건을 설명드리겠습니다.",
            sourceLanguageID: "ja-JP",
            targetLanguageID: "ko-KR"
        ))
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "We will review the clinical protocol today.",
            sourceLanguageID: "en-US",
            targetLanguageID: "ko-KR"
        ))
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "SB-PD-001 2026",
            sourceLanguageID: "en-US",
            targetLanguageID: "ko-KR"
        ))
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "本日の会議는 여기까지입니다.",
            sourceLanguageID: "ja-JP",
            targetLanguageID: "ko-KR"
        ))
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "Today we discuss 한국어 terminology.",
            sourceLanguageID: "en-US",
            targetLanguageID: "ko-KR"
        ))
        #expect(MixedLanguageUtteranceRouter.sourceText(
            from: "本日の会議を始めます。 오늘 회의를 시작하겠습니다.",
            sourceLanguageID: "ja-JP",
            targetLanguageID: "ko-KR"
        ) == "本日の会議を始めます。")
        #expect(MixedLanguageUtteranceRouter.sourceText(
            from: "오늘 회의를 시작하겠습니다.",
            sourceLanguageID: "ja-JP",
            targetLanguageID: "ko-KR"
        ) == nil)
        #expect(MixedLanguageUtteranceRouter.sourceText(
            from: "일차 평가 변수를 변경했습니다 we changed the primary endpoint",
            sourceLanguageID: "ko-KR",
            targetLanguageID: "en-US"
        ) == "일차 평가 변수를 변경했습니다 we changed the primary endpoint")
        #expect(MixedLanguageUtteranceRouter.sourceText(
            from: "We will review the FDA approval.",
            sourceLanguageID: "ko-KR",
            targetLanguageID: "en-US"
        ) == nil)
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "FDA 승인 검토합니다.",
            sourceLanguageID: "ko-KR",
            targetLanguageID: "en-US"
        ))
        #expect(MixedLanguageUtteranceRouter.shouldTranslate(
            "No.",
            sourceLanguageID: "en-US",
            targetLanguageID: "es-ES"
        ))
        #expect(!MixedLanguageUtteranceRouter.shouldTranslate(
            "Hoy revisaremos el protocolo clínico y los criterios de valoración.",
            sourceLanguageID: "en-US",
            targetLanguageID: "es-ES"
        ))
    }
}
