# Peeknook

**Local-first practice copilot in the MacBook notch.** Built on [OpenNook](https://github.com/glendonC/opennook).

Peeknook is a **multi-module OpenNook host**: the Peek practice module is the default, and you can register sibling nook apps in `HostModuleRegistry.swift` so they share one surface and module switcher.

## Requirements

- macOS 15+
- [OpenNook](https://github.com/glendonC/opennook) as a sibling checkout (`../opennook`) or edit `Package.swift` to use the Git URL
- Xcode 16+ / Swift 5.9 command line tools

## Build & run

```sh
cd peeknook
swift build
swift run Peeknook
swift test
```

- **Toggle nook:** ⌘⌥; (OpenNook default)
- **Capture & answer:** ⌘⇧P (Peeknook)

For a signed `.app`:

```sh
./Scripts/regenerate-xcodeproj.sh
open Peeknook.xcodeproj
```

## Add another nook module

Edit `Sources/PeeknookHost/HostModuleRegistry.swift`:

```swift
host.register(
    NookModuleDescriptor(id: "com.you.myapp", displayName: "My App", icon: "star")
) { context in MyModule(context: context) }
```

Use a unique reverse-DNS `id` per module (persistence and hotkeys key off it). Set `host.defaultModule` in `PeeknookHostConfiguration.swift` if Peek should not open first.

## Project layout

| Target | Role |
|--------|------|
| `PeeknookCore` | Session orchestrator, capture/inference protocols, settings |
| `PeeknookUI` | Notch home, compact glyph, settings panels |
| `PeeknookHost` | `NookModule` + `NookHostConfiguration` assembly |
| `Peeknook` | Executable entry point |

Product preferences use the `peeknook.*` `UserDefaults` keys on the module suite (`opennook.module.com.peeknook.app`). Do not write under `opennook.*`.

## First launch

Expanded home shows **Get ready** until:

1. Ollama is running  
2. Gemma 4 model is downloaded (in-app **Download model** via Ollama API)  
3. Accessibility **or** Screen Recording is granted  

Capture (⌘⇧P) stays disabled until then. Optional **Test capture** step unlocks the normal home screen.

## Models (Gemma 4 via Ollama)

Peeknook talks to **local Ollama** only (`http://127.0.0.1:11434`). Default model tags by RAM:

| RAM | Default tag |
|-----|-------------|
| ≤16 GB | `gemma4:e2b` |
| 17–24 GB | `gemma4:e4b` |
| 25+ GB | `gemma4:26b` |

```sh
brew install --cask ollama-app   # official build — bundles the model runner
ollama serve                     # or just launch Ollama.app
ollama pull gemma4:e4b           # or the tag Settings suggests
```

> The `ollama` **formula** bottle has shipped without its `llama-server` runner (requests 500 with "llama-server binary not found"). Use the `ollama-app` **cask** above.

Grant **Accessibility** (selected text) and **Screen Recording** (front-window screenshot to the vision model) when macOS prompts. Model licenses belong in this README, not in `LICENSE`.

## License

Apache 2.0 — see [LICENSE](LICENSE).
