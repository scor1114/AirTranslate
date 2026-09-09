# AirTranslate 1.8.0 포크 검토 및 수정

검토일: 2026-09-10. 이 브랜치는 원작자의 **v1.8.0**에 기존 사용자 포크의 수정 사항을 통합한 **1.8.0 / build 180.1**이다. upstream의 1.8.1 릴리스가 아니다.

## 비교 대상

- 원작자 릴리스: [himomohi/AirTranslate v1.8.0](https://github.com/himomohi/AirTranslate/releases/tag/v1.8.0), `b23579f989f9f24aa623982e0909fc259e730a06`.
- 기존 수정본: [scor1114/AirTranslate](https://github.com/scor1114/AirTranslate/tree/agent/fix-realtime-translation-session-update), `a6c66bfe7a7ba9d3e9de8c1aab27e7f75f37bb7f`.
- 공통 기준: `77814091b89ad4b161c9b366bac3f552ca99f6a6`.
- 새 브랜치: `agent/upstream-1.8-fixes`. 기존 브랜치와 작업 폴더는 보존했다.

원작자의 GPT 서비스는 공통 기준 이후 `RealtimeAudioTransportProvider.meta` 추가 외에는 바뀌지 않았다. 따라서 아래 GPT 문제는 소스상 여전히 남아 있었다. 실제 API 장애나 번역 품질을 이번에 재현했다는 뜻은 아니다.

## 기존 수정 사항의 1.8 상태

| 항목 | 원작자 1.8 상태 | 이번 반영 |
| --- | --- | --- |
| GPT Realtime Translation 요청 | 번역 전용 update에 `format`·`turn_detection`을 보내는 기존 코드 유지 | 지원 필드만 직렬화하는 기존 수정 재적용 |
| GPT 직접 번역의 무출력 후보 원인 | 입력 필터 `near_field` 유지 | 이전 비교 실험에서 선택한 `noise_reduction: null` 재적용. 입력 소스 전달 및 내용·키를 제외한 제한된 진단 로그 유지 |
| GPT Live Transcribe 연결·설정 | 기존 URL/모델 설정 유지 | `intent=transcription` URL, session 안의 모델·언어·`delay: high`, 클라이언트 발화 경계 처리 재적용 |
| 작은 소리의 무한 대기 | 강제 commit 보완 없음 | 무음/발화 경계 및 15초 분량의 아직 commit하지 않은 오디오에 대한 byte 기반 commit 보완 유지 |
| 짧은 commit 오류 | 최소 길이 차단·recoverable 분류 보완 없음 | 100ms 미만 commit 차단, commit-empty 복구 시 새 오디오 집계 보존 |
| GPT Stop 지연·마지막 발화 | 기존 종료 경로 유지 | 캡처 중지부터 시작, 마지막 전사 처리, 단계별 대기 시간·timeout 안내, 두 번째 Stop 즉시 종료 |
| Pause 중 뒤늦은 자막 | 한 번의 flush로 한정하는 보완 없음 | pause flush 동안만 수신 허용하고 이후 자막 차단 |
| GPT 번역 턴 사이 붙여쓰기 | 기존 문자열 연결 유지 | `RealtimeTranscriptAccumulator`로 턴 경계 구분. Gemini 경로는 upstream 처리 유지 |
| 통역 포함 혼합 입력 | 기능 없음 | 기본 꺼짐·세션 한정 옵션 복원. 선택한 두 언어를 전사하고 원문 언어만 Apple 번역. 명확한 대상 언어 문장만 제외 |
| 동시 `.m4a` 녹음 | 기능 없음 | 기존 녹음 기능 및 안전장치 복원. 없는 upstream 기능의 버그로 분류하지 않음 |
| 녹음 오류·삭제·종료 보호 | 기능이 없어 해당 없음 | 일부 오디오 뒤 오류가 나도 파일 보존, 32개 제한 인코딩 큐, 누락 수 안내, 활성 파일 삭제 방지, 녹음 단독 목록·동반 삭제, 종료 시 인코더 마무리, 이름 충돌 시 원본 보존 |

## 1.8 기능과의 통합

- Stage & Console 화면, Apple 자막 구간·개정·final 메타데이터, 반복 발화 보존, 장시간 롤오버, 플로팅 표시 개선을 유지했다.
- Azure MAI와 Meta Scribe의 시작·오디오 전달·종료 및 Gemini/Meta 재연결 경로를 유지했다. Azure Stop은 캡처 종료와 provider 마무리 뒤 녹음을 확정한다.
- **녹음 기본 켜짐**은 기존 사용자 결정대로 유지했다. 하단 콘솔의 녹음 아이콘 메뉴에서 끌 수 있다. GPT 모드에서는 같은 메뉴에 **통역 포함 혼합 입력**이 표시된다.
- **텍스트 파일 저장 기본 꺼짐**은 upstream 1.8 정책대로 유지했다. 설정 > 기록에서 별도로 켠다. 텍스트 저장을 꺼도 녹음 옵션이 켜져 있으면 `.m4a`가 남는다.
- 녹음만 있는 보관함 항목은 텍스트 편집을 제공하지 않는다. 기존 파일은 삭제하지 않았다.
- 원작자 공개 릴리스 안내와 포크 변경 이력을 구분했다. README의 upstream 다운로드에는 이 포크 수정이 포함되지 않는다.

## 검증

- 수정 전 upstream: `swift test` **282 tests / 33 suites 통과**.
- 통합본: `swift test` **310 tests / 35 suites 통과**.
- 기존 포크와 upstream의 테스트 함수가 모두 남아 있음을 이름·경로 기준으로 비교했다. 파라미터화 검사 때문에 함수 수와 실행 테스트 수는 다르다.
- 추가 통합 검사: 텍스트 저장 켜짐/꺼짐 × Stop 후 종료/직접 앱 종료에서 녹음 보존, 단독/연결 목록, 활성 녹음 보호 해제를 검증했다. 테스트는 임시 폴더와 분리한 설정을 사용한다.
- `git diff --check`, `script/verify_packaging_permissions.sh` 통과.
- Release 빌드, 실제 앱 1.8.0 / 180.1 메타데이터, 코드 서명·마이크 entitlement·Hardened Runtime, ZIP 무결성·추출 앱 동일성·자격 증명 패턴 검사 통과.
- ZIP SHA-256: `78fff27aae7a3688900ae20710fe601ad95ec508679369569704cfa4b49deb2a`.
- API contract 근거: [OpenAI Translation client events](https://developers.openai.com/api/reference/resources/realtime/translation-client-events). 직접 번역의 `session.update` 지원 범위와 null로 필터 비활성화하는 의미를 확인했다.

실제 마이크·시스템 오디오 → 앱 화면의 지연/품질, Apple 번역 정확도, Azure/Meta/Gemini/OpenAI 실서비스 호출은 이번 검증 범위에 포함하지 않았다. 특히 혼합 입력은 완성된 발화 단위로 표시하여 연속 발화에서 지연될 수 있으며, 문자·언어 판별은 휴리스틱이다. 직접 번역의 필터 해제는 이전 파일 실험에 근거한 설정이며 모든 마이크 환경의 개선을 보장하지 않는다.

## 로컬 빌드

```sh
swift test
./script/verify_packaging_permissions.sh
./Release/build_open_source_release.sh zip
```

결과는 `Release/product/AirTranslate.app`와 `Release/product/AirTranslate-1.8.0-180.1.zip`이다. 이 앱은 ad-hoc 서명이며 공증되지 않았다. 이 작업은 설치된 앱 교체, live capture, 태그, GitHub Release, upstream PR을 포함하지 않는다.
