# Contributor guide

Guidance for contributors and AI assistants working in this repository.

## Overview

Peeknook is a local-first practice copilot for the MacBook notch, built on [OpenNook](https://github.com/glendonC/opennook). The user triggers capture with **⌘⇧P**, optionally previews what will be sent, and receives a short streamed answer from a local Ollama vision model (Gemma 4). There is no cloud inference, ambient recording, or stealth overlay.

## Build, test, and run

```sh
swift build
swift test
swift run Peeknook        # launches the notch app
```

For a signed `.app`, run `./Scripts/regenerate-xcodeproj.sh`, then open `Peeknook.xcodeproj`.

### Runtime prerequisites

These are required for live capture but not for `swift test`:

- Ollama running locally at `http://127.0.0.1:11434`. Install via the **`ollama-app` cask**, not the Homebrew formula (see README).
- A Gemma 4 tag pulled (`gemma4:e2b`, `e4b`, or `26b`, depending on available RAM).
- Screen Recording permission (required for vision capture). Accessibility is optional and supplements capture with selected text.

### Default shortcuts

- Toggle nook: **⌘⌥;**
- Capture and answer: **⌘⇧P**

## Architecture

The project is organized into four Swift Package Manager targets:

| Target | Role |
|--------|------|
| `PeeknookCore` | Session orchestrator, capture and inference protocols, settings, usage, prompts |
| `PeeknookUI` | Notch home, compact glyph, setup and settings panels |
| `PeeknookHost` | `NookModule` integration, host configuration, module registry |
| `PeeknookExecutable` (`Peeknook`) | Executable entry point |

### Extension points

Keep new backends behind these protocols. Do not widen call sites.

- **`CaptureProviding`**: `func capture(scope:quick:) async throws -> CaptureResult`. The current implementation is `MacCaptureProvider` (ScreenCaptureKit), wired in `PeeknookServices.makeStack`.
- **`InferenceEngine`**: streams `InferenceEvent` (`.token` / `.completed(InferenceStats?)`). The current implementation is `OllamaInferenceEngine`.

`SessionOrchestrator` drives the phase machine in `SessionPhase`: `idle → capturing → previewing → inferring → result / failed`. It also owns `UsageStore` and warm-model tracking (`keep_alive`).

## Invariants

Do not break the following without an explicit product decision and migration plan.

1. **One shipped mode.** `PracticeMode.shipped = [.general]`. The enum retains `korean`, `explain`, `code`, and `chessCoach` only for persistence and migration. Do not re-expose per-language pills. General mode infers gloss, translate, and explain intent from the screen. Add a new mode only when behavior is genuinely distinct.
2. **Settings namespace is `peeknook.*` only.** Never read or write `opennook.*` keys. The module `UserDefaults` suite is `opennook.module.com.peeknook.app`.
3. **Tolerant decoding.** `PeeknookSettings` and `UsageStats` decode with `decodeIfPresent` so adding a field does not reset saved state. Keep new fields optional or defaulted. Tests guard this behavior.
4. **Host surfaces self-bound their height.** OpenNook sizes the notch panel to fit content. Any growable view (for example, a `ScrollView` in `PeekSettingsView`) must cap its own height against the notch screen `visibleFrame`, or it can push the host top bar off screen.
5. **Local-only, user-triggered capture.** No cloud inference path. No ambient or background capture. The default flow skips the confirm step. Captures are stored in the conversation thread (`ChatTurn.image`), and History shows the full timeline. Opt-in `previewBeforeInfer` surfaces `appName` and `windowTitle` before analysis. Conversation persistence is **opt-in and off by default** (`PeeknookSettings.persistConversation`): when enabled, every answered chat — screenshots included — is filed as its own thread in a local **conversation archive** (`ConversationArchiveStore`: one `<uuid>.json` per thread plus an `index.v2.json`, under `Application Support/Peeknook/Conversations/`, capped at 25 threads / ~250 MB, oldest pruned first). Past chats are listable/resumable/deletable via the History switcher; discarding a chat (**New chat**) deletes just that thread, **Done** keeps it archived, and turning the setting off purges the whole archive. A one-time migration upgrades the legacy single-file `conversation.v1.json` (`ConversationStore`, kept only as the legacy reader). Never persist captures without that opt-in.
6. **Do not embed Noru.** Noruflow remains a separate product. A future `NoruCaptureProvider` would call it as a sidecar (CLI or HTTP). Do not link Noru Rust/Tauri code into Peeknook. Do not block work on Noru integration.
7. **Privacy.** Treat captured frames as private user data. Delete temporary screenshots created during testing. Flag secrets (API keys, tokens) if they appear in a capture.

## Implementation notes

- **Gemma 4 is a reasoning model. Always send `think: false`.** When enabled, the model can spend the token budget in a hidden `thinking` field and stream empty `content`. This is most visible in quick mode, where `num_predict` is capped. Every Ollama call in this project sets `think: false`. The answer stream retries once without `think` if a model rejects the parameter, so non-reasoning models still work. The follow-up suggestion pass uses a non-streaming call with JSON-schema `format` (grammar-constrained output), not an in-band text marker.
- **Ollama runner.** The Homebrew `ollama` formula bottle has shipped without its `llama-server` runner (requests fail with "llama-server binary not found"). Use the `ollama-app` cask.
- **Warm model latency.** `keep_alive` keeps the model resident (roughly 13s cold start to sub-second warm inference). `SessionOrchestrator.modelLikelyWarm` gates loading copy on real warm state. Do not fake "Analyzing…" timers.
- **Tag-aware model matching.** `gemma4:e2b` must not satisfy a request for `gemma4:e4b`. Bare names normalize to `:latest`. See `OllamaSetupClient.matchesModel`.
- **Capture target selection.** Capture uses the window under the cursor, then frontmost, then largest. It does not use "whatever app is frontmost", which avoids wrong-screen capture on multi-monitor setups.

## Key files

| Concern | Path |
|---------|------|
| Capture | `Sources/PeeknookCore/{CaptureProviding,MacCaptureProvider,CaptureImageEncoder,CapturePermissions}.swift` |
| Session | `Sources/PeeknookCore/{SessionOrchestrator,SessionPhase,Conversation}.swift` |
| Persistence | `Sources/PeeknookCore/ConversationArchive.swift` (multi-thread archive: `ConversationThread`/`ConversationSummary`/`ConversationArchiveStore`); `ConversationStore.swift` (legacy single-file reader, migration only) |
| History switcher | `Sources/PeeknookUI/PeekConversationArchiveView.swift` (glass list of past chats) |
| a11y / localization | `Sources/PeeknookUI/{PeekAccessibility,PeekLocalization}.swift` + `Resources/Localizable.xcstrings` (route shared-component strings through `Text(peek:)`/`peekAction`) |
| Failures | `Sources/PeeknookCore/SessionFailure.swift` (structured `SessionFailure`/`RecoveryAction`); `Sources/PeeknookUI/PeekFailureView.swift` (glass recovery card) |
| Inference | `Sources/PeeknookCore/{InferenceEngine,OllamaInferenceEngine}.swift` |
| Prompts and modes | `Sources/PeeknookCore/{PromptBuilder,PracticeMode}.swift` |
| Settings and usage | `Sources/PeeknookCore/{PeeknookSettings,Usage,SystemProfile}.swift` |
| Setup | `Sources/PeeknookCore/{SetupCoordinator,OllamaSetupClient}.swift` |
| Wiring | `Sources/PeeknookCore/PeeknookServices.swift` |
| UI | `Sources/PeeknookUI/` — top-level `PeekHomeView`/`PeekSettingsView`/`PeekSetupView`/`PeekRootView`/`PeekCompactView`, design system in `PeekGlassStyle.swift` + `PeekToolbar.swift`, split sections under `PeekHome/`, `PeekSettings/`, `PeekSettingsComponents/` |
| Host | `Sources/PeeknookHost/{PeeknookModule,PeeknookHostConfiguration,HostModuleRegistry}.swift` |
| Tests | `Tests/PeeknookCoreTests/` |

## Conventions

- macOS 15+, SwiftUI, Swift Observation (`@Observable`), `@MainActor` on UI and orchestration types, strict concurrency.
- Every source file starts with `// SPDX-License-Identifier: Apache-2.0`.
- **Accessibility**: use the shared helpers in `PeekAccessibility.swift` — `peekAction(label:hint:)` for icon+text controls, `peekDecorative()` for glyphs that duplicate a label, `peekLoading(_:)` for skeletons. Don't hand-roll `accessibility*` on new shared components.
- **Localization**: `PeeknookUI` strings live in `Resources/Localizable.xcstrings`. Route visible copy through `Text(peek:)` / `PeekLocalized(_:)` (resolves against `Bundle.module`, not `Bundle.main`). Keys are human-readable English and double as the fallback; add translations in the catalog, not in code.
- Keep diffs focused and match surrounding style. Run `swift test` before declaring a change complete (currently 71 core tests). A SwiftUI **XCUITest** target still needs the generated `.xcodeproj` (`./Scripts/regenerate-xcodeproj.sh`); phase/settings/archive flows are covered today by core logic tests.
