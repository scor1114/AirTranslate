# AirTranslate 1.6.0

AirTranslate 1.6.0 adds optional audio recording alongside live transcription and translation, and reworks the OpenAI Realtime transcription path so that stopping a session finishes cleanly instead of dropping the last utterance.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or Google.

## Added

- **Audio recording is on by default.** When capture runs, the microphone or Mac audio is also written as a compressed `.m4a` file into the same folder as your transcripts. Turn it off with the **녹음 파일 저장 / Save audio file** checkbox on the main screen; the setting persists across launches and is locked while a session is active. If you update from an earlier version and do not want recordings, uncheck it before your next capture.
- Recordings made without any transcript text now appear in the transcript library as audio-only rows, so a capture that produced no text is still visible and manageable.
- Deleting a saved transcript now also deletes its paired recording, and **Delete All** removes `.m4a` files as well as `.txt` files. Both confirmation dialogs state this.
- Stopping a GPT transcription session shows a **Stopping…** state with a hint that pressing Stop again ends it immediately.

## Changed

- GPT Live Transcribe now drives turn boundaries from the app instead of server voice-activity detection, committing audio after a silence gap, after a maximum turn length, or after 15 seconds of uncommitted audio. Transcription requests use the higher-accuracy delay setting, and noise reduction is applied to microphone input only.
- Audio encoding for recordings runs on its own queue instead of the capture callback, so recording no longer competes with live captioning. If the encoder falls behind, the omitted chunk count is reported rather than silently growing memory.
- Pressing Stop now ends microphone and screen capture immediately, before waiting for the transcription service to finalize, so the macOS recording indicator turns off right away.
- The Realtime translation session no longer sends fields the current translation schema does not accept.

## Fixed

- A single unreadable audio buffer no longer deletes the entire recording. The file is closed and everything recorded up to that point is kept.
- The recording currently being written can no longer be deleted from the transcript library, either individually or through Delete All.
- A quiet speaker whose input never crosses the silence threshold no longer produces zero transcripts in GPT Live Transcribe.
- A rejected empty audio commit is now treated as recoverable instead of ending the session with a connection failure.
- Stopping in GPT transcription mode no longer appears to do nothing for several seconds, and a finalization that times out now warns that the last utterance may be missing.
- Pausing in GPT transcription mode now accepts only the pending flush rather than transcripts arriving throughout the pause.
- A recording whose transcript-based name is already taken is kept under its timestamped name and reported, instead of being reported as a failure.
- Quitting the app now waits for the recording to be finalized before exiting.

## Scope

- Apple Mode remains the default local-first transcription and translation path.
- GPT Realtime, GPT Transcription, and Gemini Live remain opt-in and continue to require user-provided API keys where applicable.
- **Recordings are written only to your local transcript folder.** This release adds local audio files; it does not upload recordings, broaden the app's data collection, or add a backend account system.
- This release does not change the existing ad-hoc signing and non-notarized distribution status.

## Verification

- The release branch is verified with the repository's tests, a release build, packaging permission checks, and an actual app launch.
- Release artifacts are rebuilt from the tagged source and checked for expected contents, checksum consistency, code-signature integrity, and sensitive files or secret patterns before upload.
- macOS Gatekeeper may still show an unidentified-developer warning because these open-source artifacts are ad-hoc signed and not Apple-notarized.

## Download

- [Repository](https://github.com/scor1114/AirTranslate)
- [AirTranslate 1.6.0 release](https://github.com/scor1114/AirTranslate/releases/tag/v1.6.0)
- [Latest stable DMG download](https://github.com/scor1114/AirTranslate/releases/latest/download/AirTranslate.dmg)
- [Upstream project](https://github.com/himomohi/AirTranslate)

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License. Release DMG and ZIP artifacts are ad-hoc signed and are not Apple-notarized; macOS may show an unidentified-developer warning on first launch.
