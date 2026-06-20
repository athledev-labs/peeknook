# Peeknook

**Complete, local-first AI for your Mac — in the notch.** Every surface. AI you customize.

Most AI tools watch a single input. Peeknook is built to cover every surface you can point it
at — your **screen**, any **app window**, and your **camera**, with more on the way. Each capture
is answered by a local model, and the whole stack is yours to customize and rewire: bring your own
model and swap it anytime, no code changes. That's what *complete* means here — not one assistant
bolted on, but a modular AI layer for everything you can show it.

It stays **local and private by default**. Capture only fires when you press the hotkey (**⌘⇧P**).
Inference runs on local models on your machine via [Ollama](https://ollama.com) (or any
OpenAI-compatible server). Saved conversations are opt-in and encrypted. No account, no cloud
round-trip.

Free and fully open-source under **[Apache-2.0](LICENSE)**. Built on
[OpenNook](https://github.com/glendonC/opennook).

**→ Download for macOS: [peeknook.com](https://peeknook.com)** ·
[GitHub Releases](https://github.com/glendonC/peeknook/releases/latest)

---

## Contents

- [Install](#install)
- [How it works](#how-it-works)
- [Privacy](#privacy)
- [Models (Ollama)](#models-ollama)
- [Contributing](#contributing)
- [Licenses](#licenses)

---

## Install

Download the signed, notarized app from **[Releases](https://github.com/glendonC/peeknook/releases/latest)**
or **[peeknook.com](https://peeknook.com)** — no Terminal required.

**Requirements:** macOS 15+, plus a local model for inference (an [Ollama](https://ollama.com)
vision model such as Gemma 4 — see [Models](#models-ollama)).

**[INSTALL.md](INSTALL.md)** walks through DMG install, Ollama.app setup, the **Get ready**
permissions, model download, and troubleshooting. The same guide is on the
[website docs](https://peeknook.com/docs/).

- **Capture & answer:** ⌘⇧P
- **Toggle nook:** ⌘⌥; (OpenNook default)

## How it works

Press ⌘⇧P and Peeknook captures the surface you point it at — the window under your cursor, the
whole display, or your camera — optionally shows you what will be sent, then streams a short answer
from a local vision model into the notch. Nothing is captured or sent until you trigger it.

It's a **multi-module OpenNook host**: the Peek module is the default, and you can register sibling
nook apps in `HostModuleRegistry.swift` so they share one surface and module switcher. Inference is
pluggable (Ollama or any OpenAI-compatible server) and the capture/inference seams are protocols you
can extend — see [Development](#development).

## Privacy

Peeknook is **local-first by default**: capture runs only when you trigger it, inference defaults to
local Ollama, and the conversation archive is off unless you enable **Save conversations**. Opt-in
**Web lookup** sends queries to DuckDuckGo; **remote Ollama**, **`:cloud` tags**, and
**model-library browse** can send data off this Mac as described in [PRIVACY.md](PRIVACY.md).

Saved chats (when enabled) are encrypted on disk but capped at **25 threads / ~250 MB** (oldest
pruned). **Done** keeps a chat in the archive; **New chat** deletes it.

## Models (Ollama)

Peeknook sends each capture to **your configured Ollama instance**. The default is **local Ollama**
on this Mac (`http://127.0.0.1:11434`). In Settings > Vision > Advanced you can point at a **remote
Ollama server** (HTTPS by default; optional **Allow insecure HTTP** for cleartext). You can also
select Ollama **`:cloud` tags** from the model library; those run through Ollama and may execute off
this Mac per Ollama's cloud offering.

Default model tags by RAM:

| RAM | Default tag |
|-----|-------------|
| ≤16 GB | `gemma4:e2b` |
| 17-24 GB | `gemma4:e4b` |
| 25+ GB | `gemma4:26b` |

```sh
brew install --cask ollama-app   # official build, bundles the model runner
ollama serve                     # or just launch Ollama.app
ollama pull gemma4:e4b           # or the tag Settings suggests
```

> The `ollama` **formula** bottle has shipped without its `llama-server` runner (requests 500 with
> "llama-server binary not found"). Use the `ollama-app` **cask** above.

### Remote Ollama and cloud tags

- **Remote server:** useful when Ollama runs on another machine on your network. Screenshots and
  chat are sent to that host.
- **`:cloud` tags:** shown with a **Cloud** badge in the model browser. Peeknook does not host
  inference; payloads go to your Ollama endpoint, which may use Ollama's cloud runtime for those tags.
- **Model library browse** contacts `https://ollama-models-api.devcomfort.workers.dev` for
  search/tag metadata only (no screenshots). Browse is not used during capture.

### OpenAI-compatible servers (LM Studio, vLLM)

Settings > Answer model > **Backend** switches inference from Ollama to any local OpenAI-compatible
server (`/v1/chat/completions`). Point it at the server address (e.g. `http://127.0.0.1:1234` for LM
Studio), pick a model from the server's `/v1/models` list, and capture as usual. Notes:

- Local-first and HTTPS-gated like Ollama: plain HTTP works for loopback only, remote servers need
  HTTPS unless you enable **Allow insecure HTTP**.
- The optional API key (most local servers need none) is stored in the macOS **Keychain**, never in
  settings files; see [PRIVACY.md](PRIVACY.md).
- These servers don't report model capabilities, so Peeknook can't verify vision support up front:
  load a multimodal model (e.g. a Qwen-VL variant) or the screenshot is silently ignored.
- Ollama setup steps don't apply on this backend; server health shows in Settings > Answer model.

### Bring your own model

Gemma 4 is the default, but the picker is open: **Answer model > Add a model…** (in Home, Setup, or
Settings) accepts any Ollama tag, pulls it if needed, and selects it, so you can try any open model
in your notch without a code change. Custom models persist and can be removed from Settings.

Because every capture sends a screenshot, **pick a model that supports image input**. Peeknook reads
the model's `/api/show` capabilities and warns when a chosen model is text-only. Note: some
otherwise-multimodal models (e.g. NVIDIA's Nemotron 3 family) run **text-only** under Ollama because
Ollama doesn't load their separate vision projector (`mmproj`) files; those ignore the screenshot
until upstream support lands.

### Third-party model licenses

Peeknook does not ship model weights. You download them through Ollama. Applicable terms:

| Component | License / terms |
|-----------|-----------------|
| Peeknook app source | [Apache 2.0](LICENSE) |
| OpenNook host | [Apache 2.0](https://github.com/glendonC/opennook/blob/main/LICENSE) |
| Ollama (runtime, user-installed) | [MIT](https://github.com/ollama/ollama/blob/main/LICENSE) |
| Gemma 4 weights (default recommendation) | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) |
| Other models you add | Each publisher's license |

---

## Contributing

Peeknook welcomes contributions. Build, test, project layout, and conventions live in
**[CONTRIBUTING.md](CONTRIBUTING.md)**; architecture and the invariants you must not break are in
**[CLAUDE.md](CLAUDE.md)**.

```sh
swift build
swift run Peeknook    # dev binary identity
swift test
```

Found a security issue? Report it through a
[private advisory](https://github.com/glendonC/peeknook/security/advisories/new) — see
[SECURITY.md](SECURITY.md). By participating you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Licenses

Apache 2.0, see [LICENSE](LICENSE). Model weights are governed by their respective publishers, not
this license — see [Third-party model licenses](#third-party-model-licenses).
