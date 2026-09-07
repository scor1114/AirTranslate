# AirTranslate Version History

## 1.6.2 - 2026-09-08

### Changed

- Direct GPT Realtime translation disables input noise reduction for both microphone and system
  audio, based on a recorded file comparison. Live microphone behavior and translation accuracy
  remain unverified.
- Connection diagnostics record bounded milestones without audio, text, credentials, or payloads.

### Fixed

- Direct GPT translation startup forwards the selected audio input source.
- Regression checks cover explicit noise-reduction null, immediate transcript deltas, and stale
  output rejection after stopping.

## 1.6.1 - 2026-08-22

### Added

- A default-off, session-only Interpreter / mixed input option for GPT Realtime that uses the
  selected source/target pair and Apple Translation without pair-specific meeting modes.

### Changed

- Mixed input routes completed GPT transcription turns by sentence and script evidence, retaining
  ambiguous input and short shared-script speech to avoid silent source loss.
- The main-screen help states that captions can be delayed until a continuous utterance is finalized.

### Fixed

- Target-language interpreter repeats can be omitted without leaving an earlier partial caption.
- Unpunctuated Korean/English mixed turns are retained instead of being discarded as target-only.
- Mixed input checks Apple Translation assets only and preserves the selected target when language
  selections would otherwise become identical.

## 1.6.0 - 2026-08-16

### Added

- Optional audio recording alongside transcription and translation, enabled by default, saved as a compressed `.m4a` beside the transcript files and switchable from the main screen.
- Audio-only transcript library rows for recordings saved without transcript text, plus recording-aware deletion in both the per-item and Delete All paths.
- A Stopping state for GPT transcription shutdown, with a second Stop press ending the session immediately.

### Changed

- GPT Live Transcribe drives turn boundaries from the client instead of server voice-activity detection and uses the higher-accuracy delay setting.
- Recording AAC encoding moved off the capture callback and the shared pipeline lock to a dedicated serial queue bounded at 32 pending buffers, with dropped chunks and bytes reported.
- Stop begins capture shutdown before waiting for transcription finalization.
- Deferred-stop is modeled as store-owned state rather than a localized status-string comparison.

### Fixed

- A sample-buffer failure after audio has been written preserves the recording instead of deleting it.
- The recording currently being written is protected from deletion.
- A byte-based commit fallback commits GPT Live Transcribe audio after 15 seconds regardless of the measured input level.
- A rejected empty audio commit is recoverable, and commits carrying less than 100 ms of audio are no longer sent.
- Paused GPT transcript acceptance is bounded to a single flush.
- Live translation joins provider turns on segment boundaries, fixing run-together output such as `배송되고거기서`. GPT realtime translation paths only; the Gemini paths keep their previous joining.
- The recording is finalized before the app exits.

## 1.5.1 - 2026-08-09

### Added

- Per-permission rows with available status or System Settings verification guidance, refreshable permission state, translation-asset download progress/error/retry feedback, and visible app version/build details.

### Changed

- The workspace, sidebar, menu bar, floating captions, transcript library, and Settings now share a minimal design system with consistent spacing, icon sizing, surfaces, selection, and hover feedback.
- Settings communicate API-key replacement, active control dependencies, caption-preview behavior, keyboard navigation, accessibility values, and Reduce Motion behavior more clearly.

### Fixed

- Voice volume is no longer interactive while translated voice output is unavailable or off.
- API-key persistence uses one session-store path instead of duplicate Settings-level Keychain writes.
- Startup API-key presence checks no longer read secret data or allow authentication UI before the first window appears.
- The About pane resolves version/build metadata from the packaged executable that is actually running.
- Failed translation-language assets can be retried, and each Settings section retains a stable scroll identity.

## 1.5.0 - 2026-08-02

### Added

- Added optional GPT Transcription with `gpt-live-transcribe` for source-only live captions when the user provides an OpenAI API key. Apple Mode remains the default local-first path.
- Added lifecycle regression tests for permission cancellation, stale callbacks, external system-audio stops, restart behavior, configuration locking, and explicit speech-input backpressure handling.

### Changed

- Apple Mode start attempts now use generation-scoped ownership so an old permission, warm-up, or callback cannot mutate a newer capture session.

### Fixed

- An external system-audio user stop now saves the active transcript, unlocks the session, and allows the next start to proceed normally.
- Speech-input backpressure is surfaced as a controlled stop instead of silently losing audio.
- Stale OpenAI and Gemini connection errors can no longer replace the current session state or expose raw provider connection details in the UI.

## 1.4.2 - 2026-07-31

### Fixed

- Release and local app signatures now embed the required microphone audio-input entitlement while retaining Hardened Runtime.
- The privacy-reset helper now resets Microphone permission, and packaging checks verify the release/debug entitlement separation before distribution.

## 1.4.1 - 2026-07-24

### Changed

- Apple-mode translated speech now waits for stable sentence boundaries during streaming and speaks final unpunctuated translations immediately when the request completes.
- Dubbing speech progress is isolated in AirTranslateCore with focused regression coverage for streaming rewrites, finalization revisions, suffix replays, priming, and repeat expiry.

### Fixed

- Prevented translated speech from repeating the tail of a restored sentence after a shorter streaming rewrite.
- Suppressed near-duplicate finalization variants and text that was already visible before dubbing was enabled.
- Prevented short suffix replays while keeping legitimate later repeated phrases speakable.

## 1.4.0 - 2026-07-10

### Added

- Periodic transcript checkpoints during active capture and native macOS capture shortcuts.
- Regression tests for long-session responsiveness, realtime provider tails, retry policies, floating-window visibility, and speech backlog limits.

### Changed

- Apple basic mode now bounds long-session MainActor work with automatic update coalescing, background translation preparation, and a bounded LRU cache.
- Gemini Live uses explicit activity detection and bounded pre-setup audio buffering.
- OpenAI translation streams partial results and applies bounded retry and timeout behavior.
- Workspace, sidebar, menu bar, floating-caption, and settings interactions have clearer state, keyboard, accessibility, and reduced-motion behavior.

### Fixed

- Preserved the final buffered words across realtime completion, pause, stop, and termination paths.
- Prevented translated speech and realtime audio queues from accumulating unbounded stale output.
- Restored off-screen floating caption windows to a visible display.
- Redacted authenticated Gemini WebSocket details from network errors shown to users.

## 1.3.6 - 2026-06-13

### Added

- Gemini 3.5 Live Translate mode for direct audio-to-live-translation sessions.
- Gemini API key storage in macOS Keychain.
- Compact LIVE Translation control for API-backed GPT and Gemini modes.
- Sidebar voice-output toggle and translated-voice volume slider.

### Changed

- GPT mode now uses OpenAI Realtime Translation for the live translation path and shows source transcript updates.
- API-backed modes now use one translated-audio output path and default voice output on.
- Apple basic mode defaults voice output off while allowing manual translated speech output.
- Settings and sidebar controls now separate Apple, GPT Realtime, and Gemini Live modes more clearly.

### Fixed

- Source-language quick changes no longer switch translation sessions to Transcribe Only mode.
- GPT realtime translation now shows the original transcript.
- GPT and Gemini live translated audio playback now uses the translated voice path consistently.
- Apple basic-mode translated speech no longer lowers the Mac system volume.

## 1.3.5 - 2026-06-13

### Changed

- Saved transcript history now loads lightweight previews first and opens full text only when a transcript is selected.
- Realtime GPT transcript updates are coalesced to reduce MainActor and UI churn during long sessions.
- Realtime audio send backlog is bounded so stalled network sends cannot accumulate without limit.
- Start/stop capture teardown is serialized before a new capture start.

### Fixed

- Very large transcript panes now render a bounded display tail even in standard session mode while preserving the full saved text.

## 1.3.4 - 2026-05-26

### Changed

- Floating caption wrapping now scales with the selected text size so larger captions keep readable text within the floating window.

## 1.3.3 - 2026-05-26

### Added

- Added a dedicated Transcribe Only output mode that shows only the original transcript pane.

### Changed

- Floating captions keep the wrapping improvements from 1.3.2-era development and stay original-only during Transcribe Only sessions.
- Transcribe Only language changes now keep the hidden target language aligned with the visible source language.

### Fixed

- Prevented blank translation-only floating captions while Transcribe Only mode is active.

## 1.3.2 - 2026-05-17

### Fixed

- Centered the empty transcript placeholder in the main workspace.

## 1.3.1 - 2026-05-16

### Changed

- Temporarily disabled Apple basic-mode source language auto-detection while language-switch handling is improved.
- Added a clear in-app notice when the disabled auto-detect toggle is clicked.

### Fixed

- Prevented saved auto-detect preferences from re-enabling the feature in this build.

## 1.3.0 - 2026-05-16

### Added

- Added input support for built-in, Bluetooth, and AirPods microphones.
- Added source language auto-detection for Apple basic mode when language inference is available.

### Changed

- Improved microphone pipeline stability for long sessions.

### Fixed

- Fixed duplicate transcript input from unstable microphone transitions.
- Reduced duplicate segments when switching capture source setup.

## 1.2.1 - 2026-05-14

### Changed

- Apple mode now keeps the visible mode and internal translation state aligned.
- GPT mode setup now uses the same session-level mode switching path as Apple mode.

### Fixed

- Fixed Apple default mode translation staying inactive while transcription continued.
- Translation unavailable states now show a clear message in the translation output.

## 1.2.0 - 2026-05-13

### Added

- Optional GPT realtime transcription and translation modes.
- Realtime translation-only path with optional translated audio playback.
- macOS Keychain storage for user-provided OpenAI API keys.
- English, Korean, Japanese, and Simplified Chinese README files.

### Changed

- GPT realtime floating captions show only the current live caption unit instead of the accumulated transcript.
- GPT realtime output is preserved without transcript lint cleanup rewriting model text.
- Saved original-plus-translation transcripts are grouped as one library item.

### Fixed

- Reduced duplicate live transcript text after paragraph cleanup or settings changes.
- Improved per-pane editing behavior for saved original and translated transcripts.

## 1.1.0 - 2026-05-10

### Added

- Centered live audio waveform meter.

### Changed

- Improved hover, pressed, active, and click-confirmation feedback for transport controls.
- Moved the live audio waveform into the center header area.

## 2026-05-09 - Library Modal UI

### Added

- Original-plus-translation saved transcripts grouped into a single library row.
- Confirmation-protected delete-all action.

### Changed

- Saved transcript management moved from the sidebar into a focused modal.

## 2026-05-09 - Transcript Control and Stability

### Added

- Configurable silence interval for paragraph breaks.

### Fixed

- Bounded speech analyzer input buffering.
- Bounded translation segment cache.
- Reduced text animation work for long transcript updates.
