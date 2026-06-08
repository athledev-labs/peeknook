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
brew install xcodegen            # one-time: the script generates the project with XcodeGen
./Scripts/regenerate-xcodeproj.sh
open Peeknook.xcodeproj
```

`regenerate-xcodeproj.sh` runs **XcodeGen** (`xcodegen generate`) against `project.yml`, so XcodeGen must be installed first; the script exits with an install hint if it is missing. Like the SPM build, the generated Xcode project / signed `.app` resolves OpenNook from the sibling `../opennook` checkout (the script requires it locally — set `OPENNOOK_PACKAGE_PATH` to point at an existing clone). `Package.swift` itself falls back to the Git URL when no sibling checkout is present, which is enough for `swift build` / `swift test` but not for `regenerate-xcodeproj.sh`.

## Developing vs using the shipped app

`swift run Peeknook` is the fastest way to hack on the project. It is **not** the same macOS identity as the notarized **Peeknook.app** (`com.peeknook.app`) you distribute to users.

macOS ties **Screen Recording** and **Accessibility** to the app bundle ID. If you build from source, System Settings may list a separate entry (often **Terminal**, **Swift**, or the debug binary path) from the **Peeknook** app in `/Applications`. Granting permission to one does **not** grant it to the other.

| Goal | Use |
|------|-----|
| Day-to-day development | `swift build` / `swift run Peeknook` — grant TCC to the binary System Settings shows |
| Pre-release / user-like testing | `./Scripts/release.sh` (or Xcode Release archive) → install the exported `.app` — grant TCC to **Peeknook** |
| What you ship | Notarized `.app` from [Releases](https://github.com/glendonC/peeknook/releases/latest) |

> For permission or Gatekeeper issues while developing, prefer testing the **signed `.app`** before filing bugs. Production users should install from the website or GitHub Releases, not `swift run`.

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
3. **Screen Recording** is granted (required, the vision model sees a screenshot)  

Capture (⌘⇧P) stays disabled until then. **Accessibility** is optional and only supplements the screenshot with selected text. Optional **Test capture** step unlocks the normal home screen.

## Models (Gemma 4 via Ollama)

Peeknook sends each capture to **your configured Ollama instance**. The default is **local Ollama** on this Mac (`http://127.0.0.1:11434`). In Settings → Vision → Advanced you can point at a **remote Ollama server** (HTTPS by default; optional **Allow insecure HTTP** for cleartext). You can also select Ollama **`:cloud` tags** from the model library; those run through Ollama and may execute off this Mac per Ollama's cloud offering.

Default model tags by RAM:

| RAM | Default tag |
|-----|-------------|
| ≤16 GB | `gemma4:e2b` |
| 17–24 GB | `gemma4:e4b` |
| 25+ GB | `gemma4:26b` |

```sh
brew install --cask ollama-app   # official build, bundles the model runner
ollama serve                     # or just launch Ollama.app
ollama pull gemma4:e4b           # or the tag Settings suggests
```

> The `ollama` **formula** bottle has shipped without its `llama-server` runner (requests 500 with "llama-server binary not found"). Use the `ollama-app` **cask** above.

### Remote Ollama and cloud tags

- **Remote server:** useful when Ollama runs on another machine on your network. Screenshots and chat are sent to that host.
- **`:cloud` tags:** shown with a **Cloud** badge in the model browser. Peeknook does not host inference; payloads go to your Ollama endpoint, which may use Ollama's cloud runtime for those tags.
- **Model library browse** contacts `https://ollama-models-api.devcomfort.workers.dev` for search/tag metadata only (no screenshots). Browse is not used during capture.

### Bring your own model

Gemma 4 is the default, but the picker is open: **Vision model → Add a model…** (in Home, Setup, or Settings) accepts any Ollama tag, pulls it if needed, and selects it, so you can try the latest open models in your notch without a code change. Custom models persist and can be removed from Settings.

Because every capture sends a screenshot, **pick a model that supports image input**. Peeknook reads the model's `/api/show` capabilities and warns when a chosen model is text-only. Note: some otherwise-multimodal models (e.g. NVIDIA's Nemotron 3 family) currently run **text-only** under Ollama because Ollama doesn't load their separate vision projector (`mmproj`) files, those will ignore the screenshot until upstream support lands.

Grant **Screen Recording** (required) when macOS prompts. Every capture includes a screenshot of the chosen window or display; visible on-screen content (including login UIs) is sent to your Ollama instance. **Accessibility** is optional and only adds **selected** text alongside the screenshot; it does not read focused password fields, but the screenshot still shows what is on screen.

### Third-party model licenses

Peeknook does not ship model weights. You download them through Ollama. Applicable terms:

| Component | License / terms |
|-----------|-----------------|
| Peeknook app source | [Apache 2.0](LICENSE) |
| OpenNook host | [Apache 2.0](https://github.com/glendonC/opennook/blob/main/LICENSE) |
| Ollama (runtime, user-installed) | [MIT](https://github.com/ollama/ollama/blob/main/LICENSE) |
| Gemma 4 weights (default recommendation) | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) |
| Other models you add | Each publisher's license |

## Privacy

Peeknook is **local-first by default**: capture runs only when you trigger it, inference defaults to local Ollama, and conversation archive is off unless you enable **Save conversations**. Opt-in **Web lookup** sends queries to DuckDuckGo; **remote Ollama**, **`:cloud` tags**, and **model-library browse** can send data off this Mac as described in [PRIVACY.md](PRIVACY.md).

Saved chats (when enabled) are encrypted on disk but capped at **25 threads / ~250 MB** (oldest pruned). **Done** keeps a chat in the archive; **New chat** deletes it.

## License

Apache 2.0, see [LICENSE](LICENSE). Model weights are governed by their respective publishers, not this license.
