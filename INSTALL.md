# Install Peeknook

Peeknook is local-first AI in your MacBook notch. You trigger capture with **⌘⇧P**, Peek sends a screenshot to a vision model on your Mac, and streams a short answer. This guide is for **downloading the app** — no Terminal required.

**Website:** [peeknook docs](https://glendonc.github.io/peeknook/docs/) · **Download:** [GitHub Releases](https://github.com/glendonC/peeknook/releases/latest)

---

## What you need

- **macOS 15** or later (Apple Silicon recommended)
- **Free disk space** for your first model pull — about **7–20 GB** depending on the tag (see [Choose your model](#choose-your-model))
- **Internet** for the first model download
- **Ollama.app** — Peeknook uses Ollama to run the vision model locally (installed separately; see below)

---

## 1. Install Peeknook

1. Download the signed **`.dmg`** from [GitHub Releases](https://github.com/glendonC/peeknook/releases/latest).
2. Open the DMG and drag **Peeknook** into **Applications**.
3. Launch Peeknook from Applications.

### If macOS blocks the app

On first launch, Gatekeeper may say the app is from an unidentified developer:

- Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**, **or**
- Right-click **Peeknook** in Applications → **Open** → confirm **Open**.

You only need to do this once.

---

## 2. Install Ollama (GUI)

Peeknook does **not** bundle Ollama. Install the official app:

1. Go to **[ollama.com/download](https://ollama.com/download)** and download **Ollama for Mac**.
2. Open **Ollama.app** and leave it running (menu bar icon). Peeknook talks to Ollama at `http://127.0.0.1:11434` on this Mac by default.

In Peeknook **Get ready**, tap **Get Ollama app** if you need the download page again.

> **Do not use** `brew install ollama` (the Homebrew **formula**). That bottle has shipped without the model runner and requests fail with errors like *llama-server binary not found*. Use **Ollama.app** from the website, or `brew install --cask ollama-app` if you prefer Homebrew.

---

## 3. First launch: Get ready

When you open Peeknook, the notch shows **Get ready** until these steps are done:

| Step | What to do |
|------|------------|
| **Ollama running** | Open Ollama.app; confirm the menu bar icon is active. |
| **Download model** | Tap **Download model** in Get ready. Peeknook pulls a Gemma 4 tag sized for your RAM (large download; stay on Wi‑Fi). |
| **Screen Recording** | Tap **Open Settings** and enable **Peeknook** under **Privacy & Security → Screen Recording**. Required — every capture sends a screenshot to your model. |
| **Accessibility** *(optional)* | Adds selected text alongside the screenshot; does not read password fields. |
| **Test capture** *(optional)* | Confirms capture works before the normal home screen unlocks. |

Capture (**⌘⇧P**) stays disabled until Ollama, the model, and Screen Recording are ready.

---

## Choose your model

Peeknook defaults to **local Ollama** on this Mac. You can pick any vision-capable model in Settings later. Suggested **Gemma 4** tags by RAM:

| RAM | Suggested tag | Approx. download |
|-----|---------------|------------------|
| 16 GB or less | `gemma4:e2b` | ~7 GB |
| 17–24 GB | `gemma4:e4b` | ~10 GB |
| 25 GB or more | `gemma4:26b` | ~18 GB |

Gemma 4 is the default recommendation, not a requirement.

---

## Capture and shortcuts

| Action | Shortcut |
|--------|----------|
| Capture and answer | **⌘⇧P** |
| Brief before capture | **⌘⇧B** |
| Toggle the notch | **⌘⌥;** |

Rebind capture and brief shortcuts in **Settings → Capture**.

---

## Optional features

| Feature | Notes |
|---------|--------|
| **Save conversations** | Off by default. When on, finished chats are encrypted locally (History switcher). |
| **Camera capture** | **⌘⇧C** — still photo, no Screen Recording required. |
| **Voice input / read aloud** | Off by default; on-device only. |
| **Web lookup** | Off by default; sends search queries to DuckDuckGo when enabled. |
| **Remote Ollama / cloud tags** | Opt-in in Settings → Answer model → Advanced. See [PRIVACY.md](PRIVACY.md). |
| **OpenAI-compatible server** | LM Studio, vLLM, etc. — skips Ollama setup; configure in Settings → Answer model. |

---

## Troubleshooting

**Ollama offline** — Open Ollama.app. Confirm the menu bar icon is active. In Settings → Answer model, the server address should be `http://127.0.0.1:11434` for local use.

**Model download failed** — Check free disk space and network. Retry **Download model** in Get ready or Settings.

**Screen Recording off** — **System Settings → Privacy & Security → Screen Recording → Peeknook**. You can also repair permissions in **Settings → Capture**.

**Wrong window captured (multi-monitor)** — Peeknook captures the window under the cursor, then frontmost, then largest. Move the cursor over the target window before **⌘⇧P**.

**Permissions granted to Terminal instead of Peeknook** — If you built from source with `swift run`, macOS may list **Terminal** or **Swift** in Screen Recording. Production users should install the **Peeknook.app** from Releases and grant permissions to **Peeknook** only.

---

## Verify your download (optional)

On [GitHub Releases](https://github.com/glendonC/peeknook/releases/latest) or in [Docs → Advanced](https://glendonc.github.io/peeknook/docs/#verify-checksum), compare the published **SHA-256** checksum with your `.dmg` file:

```sh
shasum -a 256 ~/Downloads/Peeknook*.dmg
```

---

## Privacy

By default, inference stays on this Mac and capture runs only when you press **⌘⇧P**. Full data flows: [PRIVACY.md](PRIVACY.md).

---

## Getting help

- [FAQ](https://glendonc.github.io/peeknook/faq/) — Ollama, permissions, common fixes
- [GitHub Issues](https://github.com/glendonC/peeknook/issues) — bug reports

---

## Developing from source

Contributors: see [README.md](README.md) for `swift build`, OpenNook checkout, and TCC notes for debug binaries.
