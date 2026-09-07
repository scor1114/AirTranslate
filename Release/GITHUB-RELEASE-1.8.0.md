# AirTranslate 1.8.0

AirTranslate 1.8.0 makes transcript file saving opt-in, adds Azure MAI as a preview transcription engine, and tightens Apple Mode caption handling so short final utterances and repeated sentences are preserved more reliably.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, Google, Meta, or Microsoft.

## Added

- **Azure MAI preview** is available as an optional transcription mode. After you configure an Azure Speech endpoint and API key, AirTranslate sends audio in 5-second segments to Azure Speech MAI-Transcribe-2, then uses Apple Translation for captions. Azure charges apply separately.
- Apple caption pipeline coverage now verifies audio-segment metadata, repeated final utterances, stale recognition rejection, bounded partial translation requests, and Stage rewrite presentation.

## Changed

- **Save Transcript Files** is off by default. Session text stays in memory unless file saving is enabled in Settings > Transcript, so Stop and app quit no longer create `.txt` transcript files by default.
- Apple Mode now carries audio range, segment revision, and final-result metadata through recognition, translation, display, and saved transcript staging.
- Stage captions publish first text and appended text immediately, while full rewrites are held briefly and replaced in one piece to make live captions easier to read. Floating-caption stale translation expiry is calculated from the request deadline instead of a delayed task start.

## Fixed

- Apple final results can restore prepended words that were missing from an earlier partial result without losing the utterance.
- Later repeated sentences are kept as separate speech instead of being collapsed into a previous matching sentence.
- Transcript pane copy controls remain reachable through pointer, keyboard, and accessibility focus.

## Scope

- Apple Mode remains the default local-first transcription and translation path.
- Azure MAI, Meta Scribe, GPT, and Gemini modes remain optional. Each sends the audio or text needed for the selected feature directly to the corresponding external API using a user-provided key stored in macOS Keychain.
- Azure MAI is a preview path. Local code-contract tests do not prove Azure resource availability, account quota, region support, transcription accuracy, latency, or real cloud audio success.
- This release does not add an account system or a developer-operated relay/backend server.
- This release does not change the existing ad-hoc signing and non-notarized distribution status.

## Verification

- Swift tests passed: 282 tests across 33 suites.
- Metadata stress checks passed: two 20-cycle runs plus one restored 20-cycle run.
- Release build passed in 32.01 seconds, and `./script/build_and_run.sh --verify` passed.
- Source, local ZIP, DMG, checksum, and secret-scan gates passed. The public update-set audit passed with 36 README semantic checks and 6 release assets.
- The ad-hoc `Release/product` 1.8.0/180 app launched, and the Save Transcript Files default-off UI path passed.
- Public ad-hoc Apple capture proof is still blocked on the current macOS build because Screen Recording/TCC permission did not carry over to that bundle during verification. No permission settings were changed for this release check.
- A development-signed `dist` 1.8.0 build exercised capture with the same 19.34-second audio twice and showed source plus Korean captions. With Save Transcript Files off, transcript-file changes stayed at 0. With saving on, the app saved 6 original paragraphs and 6 translated paragraphs, preserved the Yes/no utterance and two repeated final sentences, then restored saving off and stopped capture. The two app binaries have matching non-empty Mach-O section contents across 37 checked sections, while code-signature bytes differ as expected.
- Local tests, packaged artifacts, and the development-signed capture check do not prove public ad-hoc Apple capture, Azure cloud transcription, Meta/OpenAI/Gemini live connectivity, microphone capture, VoiceOver behavior, or long-session runtime behavior. Those paths require separate device/account/resource verification.
- macOS Gatekeeper may still show an unidentified-developer warning because these open-source artifacts are ad-hoc signed and not Apple-notarized.

## Download

- [Repository](https://github.com/himomohi/AirTranslate)
- [AirTranslate 1.8.0 release](https://github.com/himomohi/AirTranslate/releases/tag/v1.8.0)
- [Latest stable DMG download](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg)

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License. Release DMG and ZIP artifacts are ad-hoc signed and are not Apple-notarized; macOS may show an unidentified-developer warning on first launch, and TCC permission inheritance across updates is not guaranteed. Control-click or right-click the app and choose Open on first launch, then compare `AirTranslate.dmg.sha256` with the downloaded DMG checksum.
