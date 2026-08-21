# AirTranslate 1.6.1

AirTranslate 1.6.1 adds a generic mixed-language interpreter-input path for meetings where source
speech and a target-language interpretation alternate on the same audio stream.

AirTranslate is an independent open-source project and is not affiliated with Apple, OpenAI, or
Google.

## Added

- Added a default-off, session-only **Interpreter / mixed input** checkbox for GPT Realtime.
- The selected source and target languages are sent to GPT Live Transcribe, and accepted source
  speech is translated with Apple Translation without pair-specific meeting modes.

## Changed

- Mixed input waits for completed transcription turns, splits them at native sentence boundaries,
  and uses writing-system evidence before Natural Language classification.
- Short shared-script utterances and ambiguous mixed input are retained to favor duplicate output
  over silent source loss.
- The main-screen help states that continuous speech can delay captions until a turn is finalized.

## Fixed

- Prevented filtered target-language speech from leaving an earlier ambiguous partial caption.
- Preserved unpunctuated Korean/English mixed turns that were previously classified as target-only.
- Mixed input now checks Apple Translation assets without requiring Apple Speech assets.
- The selected target language remains stable when source and target selections would otherwise
  become identical.

## Scope and known limits

- The feature is opt-in and applies only while GPT Realtime translation is selected.
- Target-language speech containing source-script fragments such as `FDA`, `IRB`, `PK`, or `CRO`
  can be retained. Short shared-script target replies can also remain visible. No percentage
  threshold was added without representative meeting evidence.
- Partial captions are deliberately withheld in mixed mode. Captions normally appear after a
  0.6-second silence, with a 15-second uncommitted-audio fallback plus provider processing time for
  continuous speech.
- Apple Mode, direct GPT translation, GPT transcription-only, and Gemini behavior are unchanged
  when mixed input is off.
- This release keeps the existing ad-hoc signing and non-notarized distribution status.

## Verification

- `swift test`: 225 tests in 25 suites passed.
- `swift build -c release`: passed with the pre-existing `String(cString:)` deprecation warning.
- The packaged app reports version 1.6.1 build 161.
- ZIP and DMG contents, code signature, Hardened Runtime entitlement, packaging permissions, and DMG
  checksum were verified. The release binary contained no matching API-key or private-key pattern.
- The exact `Release/product/AirTranslate.app` launched successfully and quit cleanly.
- A live Japanese/Korean or English/Korean meeting remains unverified.

## Artifact checksums

- `AirTranslate-1.6.1.zip` — SHA-256 `489450d2843ec7d8444243c19172a2318b9ca9998cf61627447a1410d45efbe7`
- `AirTranslate-1.6.1.dmg` — SHA-256 `18d40e8269d7a6bae54524be4a8fe4ff54bd39c07d7050a444b25efe59ffab5a`

## Distribution notes

These artifacts are ad-hoc signed and are not Apple-notarized. macOS may show an
unidentified-developer warning on first launch.
