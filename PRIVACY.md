# Peeknook privacy policy

Last updated: 2026-06-08

Peeknook is a local-first practice copilot for the MacBook notch. This policy describes what the app processes, what stays on your Mac, and what can leave your Mac when you opt in.

## Summary

- Peeknook does **not** operate its own cloud inference service. By default, capture and answers go to **Ollama on this Mac** (`http://127.0.0.1:11434`).
- You can point inference at a **remote Ollama server** you control, or choose Ollama **`:cloud` model tags**; in those cases screenshots and chat can leave this Mac to that endpoint (and, for `:cloud` tags, to Ollama's cloud runtime as configured by Ollama).
- Capture happens **only when you press the capture hotkey** (default ⌘⇧P).
- Conversation archive and web lookup are **off by default**.
- Peeknook does **not** include analytics or crash telemetry in the current release.

## What Peeknook processes

### Screenshots (required for vision answers)

When you capture, Peeknook takes a screenshot of the window or display under your cursor and sends it to your configured Ollama instance for analysis. Screenshots exist in memory for the active chat.

Screenshots are **pixel captures of what is on screen**. They can include passwords, tokens, messages, or other sensitive content if it is visible in the captured area (for example, unmasked text or masked password bullets in a login form). Peeknook does not redact screenshot pixels.

### Optional selected text

If you grant Accessibility permission, Peeknook may read **selected text** from the focused field to supplement the screenshot. It does **not** read focused field values, and it skips secure/password fields (`AXSecureTextField` and similar). That restriction applies to extracted text only — **not** to the screenshot, which still shows whatever is visible on screen.

When **Web lookup** is enabled, Peeknook skips searches when capture context looks like a secret (API keys, tokens) or a password-manager window.

### Prompts and answers

Your questions and the model's answers are kept in the active conversation thread in memory. While **Save conversations** is off, screenshot pixels stay in memory only for the active chat — Peeknook does not write screenshot files to disk during capture.

If you enable **Save conversations**, the full thread (screenshots included) is written to local files.

**Shipped app (sandboxed):**

`~/Library/Containers/com.peeknook.app/Data/Library/Application Support/Peeknook/Conversations/`

**Development builds** (`swift run`, unsigned binaries) may write the non-container path:

`~/Library/Application Support/Peeknook/Conversations/`

Each chat is one encrypted `<uuid>.json` file. Screenshot pixels are stored separately under `blobs/<uuid>.jpg` in the same Conversations folder, **encrypted with the same AES-GCM Keychain key** as the thread JSON (legacy installs may still have plaintext blob files until those threads are saved again). A separate **`index.v2.json`** lists thread metadata for History: thread id, derived title, created/updated timestamps, turn count, and whether the thread includes a screenshot. The index is **encrypted** the same way as the thread files and contains no screenshot pixels or full message bodies; a plaintext index written by an earlier version is re-encrypted automatically on the next launch. Once the archive has been sealed at least once (tracked by a tamper-resistant Keychain marker), a later plaintext index or thread is rejected on read, so a downgraded file planted on disk can't surface.

The archive keeps at most **25 threads** and about **250 MB** total; when limits are exceeded, the **oldest** threads are deleted automatically.

### Usage stats

Peeknook records local usage metadata (capture counts, token estimates, timing) in your module UserDefaults suite. This does not include screenshot pixels or conversation text. You can reset stats in Settings → Data.

## What stays on your Mac by default

- Inference defaults to local Ollama at `http://127.0.0.1:11434`.
- Usage stats stay in local preferences (`opennook.module.com.peeknook.app` UserDefaults suite).
- Conversation archive is **off by default**.
- Model-library browse does not run until you open **Manage models** / **Browse**; it does not send screenshots.

## When data can leave your Mac

You control the following opt-in or configuration-dependent features:

| Feature | Default | What leaves your Mac |
|---------|---------|----------------------|
| Web lookup | Off | Search query to DuckDuckGo HTML (`html.duckduckgo.com`) |
| Remote Ollama URL | Off (local default) | Screenshots, prompts, and answers to the Ollama host you configure. HTTPS is required unless you enable **Allow insecure HTTP** (cleartext). |
| Ollama `:cloud` model tags | Off (not the default model) | Same as inference above: payloads go to your configured Ollama endpoint; `:cloud` tags may be executed on Ollama's cloud infrastructure per Ollama's behavior. |
| Model library catalog browse | Only when you browse | Search terms and model/tag names to `https://ollama-models-api.devcomfort.workers.dev` (community proxy for ollama.com library metadata). No screenshots. |
| Save conversations | Off | Nothing leaves your Mac; active screenshots stay in memory only (no blob files on disk). When on, encrypted thread JSON, encrypted screenshot blobs, and the encrypted metadata index stay local. |
| Voice input | Off | On-device speech recognition (Microphone + Speech Recognition permissions) |
| Read answers aloud | Off | On-device text-to-speech; no network |

## Data retention and deletion

- Each answered turn is saved to the archive when **Save conversations** is on (after the model finishes).
- **Done** returns to the home screen but **keeps** the thread in the archive and in memory (resumable until you start a new capture or tap **New chat**).
- **New chat** deletes the active thread from the archive (when Save conversations is on) and clears it from memory.
- Individual past chats can be deleted from **Past chats** / History.
- Turning **Save conversations** off purges the entire archive.
- When the archive exceeds **25 threads** or **~250 MB**, Peeknook deletes the oldest threads automatically.
- **Reset stats** clears usage metadata in Settings → Data.
- Uninstalling Peeknook does not automatically delete archive files. Remove the Conversations folder under the paths above (use the **container** path for the shipped app).

## Third-party services

- **Ollama** (user-installed or user-configured): runs models locally or on a server/endpoint you configure, including optional `:cloud` tags.
- **DuckDuckGo** (opt-in web lookup only): HTML search results.
- **Ollama model catalog proxy** (model library browse only): `https://ollama-models-api.devcomfort.workers.dev` — tag and search metadata from the public Ollama library; not operated by Peeknook and not used during capture inference.

## Contact

Report privacy questions or issues on GitHub: https://github.com/glendonC/peeknook/issues

## Changes

We may update this policy as features change. The in-app About section links to this document.
