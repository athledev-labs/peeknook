# Contributing to Peeknook

Thanks for the interest. Peeknook is a small, opinionated app built on
[OpenNook](https://github.com/glendonC/opennook). For anything larger than a typo or a one-file fix,
**open an issue first** to align on approach — and read [CLAUDE.md](CLAUDE.md), the full contributor
guide (architecture, invariants, conventions). This file is the short version.

## Requirements

- macOS 15+
- [OpenNook](https://github.com/glendonC/opennook) as a sibling checkout (`../opennook`), or edit
  `Package.swift` to use the Git URL
- Xcode 16+ / Swift 5.9 command line tools

## Local setup

```sh
swift build
swift run Peeknook    # launch the notch app (dev binary identity)
swift test            # 931 core tests
```

For a signed `.app` (signing, Cmd-R in Xcode):

```sh
brew install xcodegen
./Scripts/regenerate-xcodeproj.sh
open Peeknook.xcodeproj
```

`Peeknook.xcodeproj` is a generated artifact — `project.yml` is the source of truth, and
`regenerate-xcodeproj.sh` runs XcodeGen against it. Both build paths compile the same SwiftPM
modules. The generated project resolves OpenNook from the sibling `../opennook` checkout (set
`OPENNOOK_PACKAGE_PATH` to point at an existing clone); `Package.swift` falls back to the Git URL for
`swift build` / `swift test` but not for `regenerate-xcodeproj.sh`.

### Developing vs the shipped app

`swift run Peeknook` is **not** the same macOS identity as the notarized **Peeknook.app**
(`com.peeknook.app`) you distribute. macOS ties Screen Recording, Accessibility, and Camera to the
bundle ID, so granting permission to the dev binary does not grant it to the shipped app, and vice
versa.

| Goal | Use |
|------|-----|
| Day-to-day development | `swift build` / `swift run Peeknook`: grant TCC to the binary System Settings shows |
| Pre-release / user-like testing | `./Scripts/release.sh` (or Xcode Release archive), then install the exported `.app`: grant TCC to **Peeknook** |
| What you ship | Notarized `.app` from [Releases](https://github.com/glendonC/peeknook/releases/latest) |

### First launch (from source)

Expanded home shows **Get ready** until: (1) Ollama is running, (2) a Gemma 4 model is downloaded,
(3) Screen Recording is granted. Capture (⌘⇧P) stays disabled until then. Accessibility is optional
and only supplements the screenshot with selected text. End-user setup is in
[INSTALL.md](INSTALL.md).

## Project layout

| Target | Role |
|--------|------|
| `PeeknookCore` | Session orchestrator, capture/inference protocols, settings, prompts, usage |
| `PeeknookUI` | Notch home, compact glyph, setup and settings panels |
| `PeeknookHost` | `NookModule` integration, host configuration, module registry |
| `Peeknook` | Executable entry point |

Product preferences use the `peeknook.*` `UserDefaults` keys on the module suite
(`opennook.module.com.peeknook.app`). Never write under `opennook.*`.

### Add another nook module

Edit `Sources/PeeknookHost/HostModuleRegistry.swift`:

```swift
host.register(
    NookModuleDescriptor(id: "com.you.myapp", displayName: "My App", icon: "star")
) { context in MyModule(context: context) }
```

Use a unique reverse-DNS `id` per module (persistence and hotkeys key off it). Set
`host.defaultModule` in `PeeknookHostConfiguration.swift` if Peek should not open first.

## Coding conventions

- **SPDX headers.** Every Swift file starts with `// SPDX-License-Identifier: Apache-2.0`.
- **Strict concurrency.** New code compiles clean under the strict checker; no `@unchecked Sendable`
  without a written reason.
- **`@MainActor` where it belongs.** UI types and the orchestrator are `@MainActor`; pure data types
  are not. The project uses Swift Observation (`@Observable`).
- **Extension points stay behind protocols.** New capture or inference backends implement
  `CaptureProviding` / `InferenceEngine` — don't widen call sites.
- **Accessibility + localization.** Route visible copy through `Text(peek:)` and the shared helpers
  in `PeekAccessibility.swift`; strings live in `Resources/Localizable.xcstrings`, not inline.
- **Tests.** Run `swift test` before declaring a change complete. Anything non-trivial needs coverage.

The [invariants in CLAUDE.md](CLAUDE.md) — one shipped mode, the `peeknook.*` namespace, tolerant
decoding, local-first/user-triggered capture, Noru stays a sidecar, privacy — must not be broken
without an explicit product decision.

## Submitting a change

1. Branch off `main` (don't commit on `main` directly).
2. Make the change. Run `swift build && swift test` locally.
3. Keep diffs focused and match surrounding style.
4. Open a PR using the template. CI must be green before merge.

## License

By contributing, you agree your contributions are licensed under [Apache-2.0](LICENSE). Model weights
you use are governed by their own publishers, not this license.
