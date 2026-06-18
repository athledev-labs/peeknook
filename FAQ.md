# Frequently asked questions

Quick answers for installing and using Peeknook on macOS.

---

## Getting started

### What do I need before Peeknook works?

- **macOS 15** or later on an **Apple Silicon** Mac
- **Peeknook.app** from [GitHub Releases](https://github.com/glendonC/peeknook/releases/latest)
- **[Ollama.app](https://ollama.com/download)** running locally (not the Homebrew formula)
- A **vision model** pull (Gemma 4 recommended; about **7-20 GB** depending on tag)
- **Screen Recording** permission for **Peeknook** in System Settings

Full steps: [Install guide](https://glendonc.github.io/peeknook/docs/).

### Why Ollama.app and not `brew install ollama`?

The Homebrew **formula** has shipped without the model runner (`llama-server`). Requests fail with errors like *llama-server binary not found*. Use **Ollama.app** from [ollama.com/download](https://ollama.com/download) or:

```sh
brew install --cask ollama-app
```

### Which Gemma 4 tag should I download?

| RAM | Suggested tag | Approx. download |
|-----|---------------|------------------|
| 16 GB or less | `gemma4:e2b` | ~7 GB |
| 17-24 GB | `gemma4:e4b` | ~10 GB |
| 25 GB or more | `gemma4:26b` | ~18 GB |

Peeknook can pull the model from **Get ready** on first launch.

### Does Peeknook work on Intel Macs?

v1 builds target **Apple Silicon**. Intel Macs are not supported for the shipped release.

---

## Permissions

### Why does Peeknook need Screen Recording?

Every capture sends a **screenshot** of the window or display you choose to your local vision model. macOS requires Screen Recording permission for that. Peeknook does **not** record in the background: only when you press the capture hotkey (default **⌘⇧P**).

### I granted Screen Recording to Terminal, not Peeknook

If you ran `swift run Peeknook` from source, macOS may list **Terminal** or **Swift** instead of **Peeknook**. Production installs should use the **signed app** from Releases (`com.peeknook.app`) and grant permission to **Peeknook** only.

### Is Accessibility required?

**No.** Accessibility optionally adds **selected text** alongside the screenshot. Password fields are skipped for text extraction (screenshots still show visible pixels).

---

## Privacy and data

### Does Peeknook send my screen to the cloud?

**Not by default.** Inference goes to **Ollama on this Mac** (`http://127.0.0.1:11434`). Remote Ollama, `:cloud` tags, web lookup, and third-party backends are **opt-in**. See [Privacy Policy](https://glendonc.github.io/peeknook/privacy/).

### Does Peeknook watch my screen in the background?

**No.** Capture runs only when **you** trigger it. There is no ambient or stealth recording.

### Are conversations saved automatically?

**No.** **Save conversations** is off by default. When enabled, threads are encrypted locally on your Mac.

---

## Using Peeknook

### Wrong window captured on multiple monitors

Peeknook picks the window **under the cursor**, then frontmost, then largest. Move the cursor over the target window before **⌘⇧P**.

### Capture is disabled / grayed out

Complete **Get ready**: Ollama running, model downloaded, Screen Recording granted. Check **Settings > Capture** for permission repair.

### Ollama offline errors

Open **Ollama.app** and confirm the menu bar icon is active. Default server: `http://127.0.0.1:11434` in Settings > Answer model.

### What are the default shortcuts?

| Action | Shortcut |
|--------|----------|
| Capture and answer | **⌘⇧P** |
| Brief before capture | **⌘⇧B** |
| Camera still (optional) | **⌘⇧C** |
| Toggle notch | **⌘⌥;** |

Rebind capture and brief in **Settings > Capture**.

---

## Download and updates

### How do I verify my DMG?

Compare the SHA-256 on [GitHub Releases](https://github.com/glendonC/peeknook/releases/latest) or in [Docs > Advanced](https://glendonc.github.io/peeknook/docs/#verify-checksum):

```sh
shasum -a 256 ~/Downloads/Peeknook*.dmg
```

### macOS says the app is from an unidentified developer

Open **System Settings > Privacy & Security** and click **Open Anyway**, or right-click Peeknook > **Open** once. The shipped build is signed and notarized.

### How do I get updates?

v1 has no in-app updater. Check [GitHub Releases](https://github.com/glendonC/peeknook/releases/latest) or the [Changelog](https://glendonc.github.io/peeknook/changelog/).

---

## Report a bug

Open a [GitHub Issue](https://github.com/glendonC/peeknook/issues). Include:

- macOS version
- Peeknook version (**Settings > About**)
- Ollama running (yes/no) and model tag
- Screen Recording granted to Peeknook (yes/no)
- Steps to reproduce, expected vs actual

Do not paste screenshots with passwords, API keys, or private messages unless redacted.
