# Live Captions (experimental, community-extensible)

Status: **experimental developer preview, off by default** (`PeeknookSettings.captionEnabled`).
This document is the on-ramp for anyone who wants to make on-device, private live
caption + translation actually good.

## The idea

Tap whatever audio is playing on your Mac, transcribe it on-device, translate it, and
show rolling subtitles in the notch. Private by default (no audio leaves the machine
unless a profile explicitly opts into remote translation), always user-armed, always
bounded. It is the "hearing" surface of Peeknook's local-first, multi-surface vision.

It is *not finished*. The engine bundled today is a humble baseline. The hard parts are
real, and they are spelled out below so you can attack the right one.

## Why this is hard (what we learned)

A "good" experience has two stages with very different maturity:

1. **Speech → source text (streaming ASR).** Effectively solved, but the *good* building
   block is OS-gated. Apple's `SpeechAnalyzer` / `SpeechTranscriber` (WWDC25, **macOS 26+**)
   is purpose-built for this: fully on-device, private, with immediate "volatile" partial
   results replaced by "finalized" results as an in-order async stream. That streaming
   model is exactly what fixes a chunk-on-pause prototype's multi-second dropout. It is
   **not available on the macOS 15 floor**, so today the only on-device option is
   Whisper-streaming (good interim latency ~0.45s per word, but stable text trails by
   ~3.3s; and chunk-on-pause Whisper, which we tried, lags 2-4s and drops short utterances).

2. **Source text → target text (translation).** The genuinely hard, *irreducible* part.
   Simultaneous machine translation has a tunable but unavoidable latency-vs-quality
   tradeoff (wait-k and attention-confidence policies): near-offline quality only arrives
   at a few seconds of lag, and the encouraging published numbers (BLEU ~30) are
   German→English. Harder pairs with heavy reordering (Korean→English: verb-final, so the
   translator must wait for more of the sentence) are worse. On-device NMT only matches
   cloud quality in a narrow regime (in-domain, fine-tuned, short text); for arbitrary,
   long-form audio it falls short of cloud, so a fully-private build trades some quality
   for privacy, while a hybrid (on-device ASR + opt-in cloud MT) raises the ceiling at a
   privacy cost.

**Verdict:** a "good enough" version is buildable today (Whisper-streaming + a small
streaming MT model, accepting a few seconds of lag); a genuinely *great* fully-on-device
version is largely gated on raising the floor to macOS 26 `SpeechAnalyzer` plus a
domain-tuned small MT engine. Live conversation latency is not achievable for translation;
"subtitles for content you're watching" is.

### Sources

- Apple `SpeechAnalyzer`/`SpeechTranscriber`: WWDC25 session 277; `developer.apple.com/documentation/speech/speechtranscriber`
- Whisper streaming latency: arXiv 2507.10860 (WhisperKit), arXiv 2307.14743 (Whisper-Streaming)
- Simultaneous MT tradeoff: arXiv 2203.02459, arXiv 2508.13358; TACL 2025 "How Real is Your Real-Time SimulST System?"
- On-device NMT quality: arXiv 2601.02641

## What's implemented today

- The **caption surface**: bounded, always-indicated, always-disarmed-on-exit, local-first
  with a fail-closed remote-egress gate (see invariant 5 in `CLAUDE.md`). This is the hard,
  privacy-load-bearing scaffolding, and it's done and tested.
- A **baseline engine**: `RotatingSFSpeechTranscriber` (on-device `SFSpeechRecognizer`,
  zero extra dependencies). It transcribes the source language; translation is a separate
  pass through your configured model. Quality and latency are limited. This is the humble
  starting point, not the destination.
- The pure routing/segmentation policies (`CaptionEnginePolicy`, etc.), unit-tested.

## How to contribute an engine

The whole feature is built behind one seam so a new engine is a drop-in, never a new
branch in the coordinator:

```
protocol StreamingTranscribing {
    func start(plan: CaptionTranscriptionPlan,
               onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
               onLevel:   @escaping @Sendable (Float) -> Void) async throws
    func stop()
    var canTranslateToEnglish: Bool { get }   // default false
}
```

1. **Implement `StreamingTranscribing`** in an isolated target (so PeeknookCore and its
   fast test suite never link a heavy ML stack — the stripped `PeeknookWhisper` target is
   the template). Emit `TranscriptSegment`s; drive `onLevel` if you can meter.
2. **Honor the contract:** on-device only, fail closed (throw
   `SpeechRecognitionError.onDeviceUnavailable` before tapping audio if the model/locale is
   unavailable), and make `stop()` synchronously drop all further segments.
3. **If your engine translates in its own pass** (e.g. Whisper's translate task →
   English), return `canTranslateToEnglish == true`. `CaptionEnginePolicy` will then route
   an English target through the single-pass path and the coordinator skips the separate
   LLM translate pass. Otherwise leave it `false` and the LLM does the translation.
4. **Wire it** in `PeeknookDependencies.makeProductionStreamingTranscriber()` or inject it
   via `PeeknookDependencies.production(streamingTranscriberOverride:)`. That is the only
   wiring point.

Do not widen the seam or add engine branches to `CaptionCoordinator`. Decisions belong in
pure, testable policies; the coordinator and the engine read the same
`CaptionTranscriptionPlan`.

### Recommended next engine

`SpeechAnalyzer` / `SpeechTranscriber` on macOS 26. It makes the ASR half of the problem
disappear (on-device, private, streaming partials, Korean supported), which lets you spend
your effort on the translation stage and the subtitle UX. Plugging it in is one
`StreamingTranscribing` conformer behind this seam.

## Privacy invariants you must keep

- **On-device, fail closed.** No network ASR fallback, ever.
- **Local-first translation.** Audio-derived text must not egress to a remote/`:cloud`
  endpoint unless the active profile opted in (`captionAllowRemote`); the arm-time gate
  fails closed.
- **Always armed, indicated, bounded.** Captures only while the user armed a caption; a
  persistent indicator + Stop; a mandatory auto-disarm cap the user cannot disable; disarm
  on every exit. See `CaptionCoordinator` and invariant 5 in `CLAUDE.md`.

## Open problems worth a PR

- A streaming ASR conformer (macOS 26 `SpeechAnalyzer`, or a streaming-Whisper wrapper for
  macOS 15) replacing chunk-on-pause.
- A small on-device streaming MT engine good enough for hard pairs (Korean→English) on
  arbitrary audio, or a clean opt-in hybrid (on-device ASR + cloud MT) behind the existing
  egress gate.
- Subtitle-grade UX: short rolling lines and an in-place-revisable "forming" tail instead
  of paragraph blobs.
- Confirming `ScreenCaptionKit` system-audio capture entitlements cover arbitrary app audio
  without a virtual-audio-device dependency.
