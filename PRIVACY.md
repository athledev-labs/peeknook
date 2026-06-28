# Peeknook privacy policy

Last updated: 2026-06-16

Peeknook is local-first AI for Mac in the MacBook notch. This policy describes what the app processes, what stays on your Mac, and what can leave your Mac when you opt in.

## Summary

- Peeknook does **not** operate its own cloud inference service. By default, capture and answers go to **Ollama on this Mac** (`http://127.0.0.1:11434`).
- You can point inference at a **remote Ollama server** you control, or choose Ollama **`:cloud` model tags**; in those cases screenshots and chat can leave this Mac to that endpoint (and, for `:cloud` tags, to Ollama's cloud runtime as configured by Ollama).
- Capture happens **only when you start it**: you press the capture hotkey (default ⌘⇧P); or, for the camera, you open the live camera preview (default ⌘⇧C) and **press the shutter**; or you arm a **Live session** and **Refresh**, which can run on a **timer you set** while the **Live** indicator and **Stop** stay visible. There is no hidden, ambient, or always-on recording.
- Conversation archive and web lookup are **off by default**.
- Peeknook does **not** include analytics or crash telemetry in the current release.

## What Peeknook processes

### Screenshots (required for vision answers)

When you capture, Peeknook takes a screenshot of the window or display under your cursor and sends it to your configured Ollama instance for analysis. Screenshots exist in memory for the active chat.

Screenshots are **pixel captures of what is on screen**. They can include passwords, tokens, messages, or other sensitive content if it is visible in the captured area (for example, unmasked text or masked password bullets in a login form). Peeknook does not redact screenshot pixels.

### Optional selected text

If you grant Accessibility permission, Peeknook may read **selected text** from the focused field to supplement the screenshot. It does **not** read focused field values, and it skips secure/password fields (`AXSecureTextField` and similar). That restriction applies to extracted text only, **not** to the screenshot, which still shows whatever is visible on screen.

When **Web lookup** is enabled, Peeknook skips searches when capture context looks like a secret (API keys, tokens) or a password-manager window.

### Camera photos (camera flow, shutter-only)

Pressing the camera hotkey (default ⌘⇧C) opens a **live camera preview inside the notch**. While the preview is open, frames stream from the camera to the on-screen preview only: **nothing is captured, stored, or sent**. A photo is taken only when you press **Shutter**; it then follows exactly the same path as a screenshot: sent to your configured Ollama instance for the answer, kept in memory for the active chat, and written to the conversation archive only if **Save conversations** is on.

The camera session is torn down (camera light off) whenever the preview closes: on Shutter, on Cancel, when the notch collapses or hides, and when you switch away from Peeknook. Camera access requires the macOS Camera permission, which is requested the first time you open the preview. The camera-only flow never requires Screen Recording.

### System audio (optional, transcribed on device)

**Hear system audio** (in Settings under Capture, **off by default**) lets a profile capture what is playing on this Mac (a meeting, a video, or a call) alongside the screen. It is captured only when you trigger a capture for a profile that includes the system-audio ground **and** this setting is on; nothing is recorded the rest of the time. Each capture records a **short, bounded window** of audio, not a continuous stream.

The audio is turned into text **on this Mac**: Peeknook transcribes the window with on-device speech recognition, and the audio itself is not written to disk or sent anywhere. The resulting **transcript text** is then added to the prompt and **sent to your configured inference endpoint** along with the screenshot, exactly like the rest of your prompt. If you have pointed Peeknook at a **remote Ollama server** or chosen an Ollama **`:cloud` tag**, the transcript leaves this Mac to that endpoint. System audio requires both the macOS **Screen Recording** and **Speech Recognition** permissions.

### Live session (armed refresh)

When you turn on **Live session** (Settings > Capture, **off by default**), an answered chat gains a **Go live** control. Arming a chat keeps it in context and lets you **Refresh** (capture the latest screen into that chat) without starting over. A live session is **armed only by you**: nothing arms automatically, a persistent **Live** indicator and a **Stop** stay visible while it is armed, and capture stays under your control.

A refreshed frame is a **screenshot**: the same pixel capture, with the same sensitivity, as any other capture (it can include whatever is on screen). A manual **Refresh** updates the chat's pending context **in memory** and sends nothing to the model on its own; like any capture it goes to your configured Ollama only when you ask, and refreshed frames follow the same **Save conversations** rules.

Two optional behaviors, both **off by default** and only while a chat is armed: a **timed** refresh captures the latest screen automatically on an interval you set (still into in-memory context, still sent to the model only when you ask), and **auto-respond** then answers automatically after each timed refresh. Auto-respond is the one path where an armed session sends to your configured Ollama (including a **remote** or **`:cloud`** endpoint) on a recurring, hands-off basis until you stop it. Both are **rate-capped**, **pause when the context window is full**, and stay clearly indicated; neither adds a capture surface beyond the screen Refresh you already armed.

Live is **not ambient recording**: you arm it per chat, it is always indicated, and you choose the rules. By default the session **disarms (and stops refreshing)** when you press **Stop** or **Done**, start a **New chat**, switch or delete a chat, or whenever the notch **collapses or hides** or you **switch away** from Peeknook (the same kill-paths as the camera). The optional **Keep Live after Done** (Settings > Capture, also **off by default**) changes only **Done**: the chat stays armed when you return to the home screen, where a **Live** indicator and **Stop** remain and **Resume** re-enters it. While you are on the home screen the session is **paused (nothing is captured or sent there)**, and the last refreshed frame stays in memory only (so an answer after a long pause can reflect an older screen); every other exit still fully disarms.

When **Keep watching** is on (Settings > Capture, **off by default**), an armed Live session may continue refreshing past Done for a maximum time you choose (15/30/60 min). A live countdown is always shown in the **Live** indicator, any interaction (a refresh, an answer, a question) resets it, and the session **auto-disarms** when the timer expires; it can never run indefinitely or without that visible countdown. While paused at the idle home, nothing is captured. Leaving **Keep watching** off keeps today's behavior exactly.

### Prompts and answers

Your questions and the model's answers are kept in the active conversation thread in memory. While **Save conversations** is off, screenshot pixels stay in memory only for the active chat; Peeknook does not write screenshot files to disk during capture.

If you enable **Save conversations**, the full thread (screenshots included) is written to local files.

**Shipped app (sandboxed):**

`~/Library/Containers/com.peeknook.app/Data/Library/Application Support/Peeknook/Conversations/`

**Development builds** (`swift run`, unsigned binaries) may write the non-container path:

`~/Library/Application Support/Peeknook/Conversations/`

Each chat is one encrypted `<uuid>.json` file. Screenshot pixels are stored separately under `blobs/<uuid>.jpg` in the same Conversations folder, **encrypted with the same AES-GCM Keychain key** as the thread JSON (legacy installs may still have plaintext blob files until those threads are saved again). A separate **`index.v2.json`** lists thread metadata for History: thread id, derived title, created/updated timestamps, turn count, and whether the thread includes a screenshot. The index is **encrypted** the same way as the thread files and contains no screenshot pixels or full message bodies; a plaintext index written by an earlier version is re-encrypted automatically on the next launch. Once the archive has been sealed at least once (tracked by a tamper-resistant Keychain marker), a later plaintext index or thread is rejected on read, so a downgraded file planted on disk can't surface.

The archive keeps at most **25 threads** and about **250 MB** total; when limits are exceeded, the **oldest** threads are deleted automatically.

### Usage stats

Peeknook records local usage metadata (capture counts, token estimates, timing) in your module UserDefaults suite. This does not include screenshot pixels or conversation text. You can reset stats in Settings > Data.

## What stays on your Mac by default

- Inference defaults to local Ollama at `http://127.0.0.1:11434`.
- Usage stats stay in local preferences (`opennook.module.com.peeknook.app` UserDefaults suite).
- Conversation archive is **off by default**.
- Model-library browse does not run until you open **Manage models** / **Browse**; it does not send screenshots.
- The optional **OpenAI-compatible backend** (Settings > Answer model > Backend) targets a local
  server (LM Studio, vLLM) by default. Its optional API key is stored **only in the macOS Keychain**
  (service `com.peeknook.app.inference-credentials`, device-local, not synced), never in
  UserDefaults, settings files, or logs; requests carry it only as an `Authorization` header.

## When data can leave your Mac

You control the following opt-in or configuration-dependent features:

| Feature | Default | What leaves your Mac |
|---------|---------|----------------------|
| Web lookup | Off | Search query to DuckDuckGo HTML (`html.duckduckgo.com`) |
| Remote Ollama URL | Off (local default) | Screenshots, prompts, and answers to the Ollama host you configure. HTTPS is required unless you enable **Allow insecure HTTP** (cleartext). |
| OpenAI-compatible backend | Off (Ollama is the default backend) | Screenshots, prompts, and answers to the OpenAI-compatible server you configure (`/v1/chat/completions`). The same HTTPS gate applies: plain HTTP is loopback-only unless you enable **Allow insecure HTTP**. The optional API key lives in the Keychain and is sent only to that server. |
| Profile instructions | No instruction by default | A profile's standing instruction (Settings > Profiles) is added to every prompt for that profile, so (like the rest of the prompt) it goes wherever your inference server is. Keep secrets out of instructions if you point Peeknook at a remote server. |
| Ollama `:cloud` model tags | Off (not the default model) | Same as inference above: payloads go to your configured Ollama endpoint; `:cloud` tags may be executed on Ollama's cloud infrastructure per Ollama's behavior. |
| Model library catalog browse | Only when you browse | Search terms and model/tag names to `https://ollama-models-api.devcomfort.workers.dev` (community proxy for ollama.com library metadata). No screenshots. |
| Live session | Off | When armed, **Refresh** captures the latest screen into the chat in memory; like any capture it goes to your configured Ollama only when you ask. Optional **timed** refresh captures automatically on your interval; optional **auto-respond** then answers automatically (rate-capped, pauses at full context): the one recurring, hands-off path to your configured Ollama (incl. remote / `:cloud`). Optional **Keep Live after Done** keeps the chat armed on the home screen (**paused, no capture there**) until Resume or any exit. Optional **Keep watching** sets a maximum armed time (15/30/60 min) after which the session **auto-disarms itself**; a countdown shows in the **Live** indicator and any interaction resets it. Armed only by you, always with a **Live** indicator and **Stop**; every exit except a kept-armed Done disarms (including notch collapse / switch away). |
| System audio | Off | Captured only with a system-audio profile and the setting on; needs Screen Recording and Speech Recognition. A short window of audio is transcribed **on this Mac** (the audio is never sent), then the **transcript text** is added to your prompt and sent to your configured inference endpoint along with the screenshot, including a **remote** or **`:cloud`** endpoint if you point Peeknook at one. |
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
- **Reset stats** clears usage metadata in Settings > Data.
- The OpenAI-compatible API key is removed via **Clear API key** in Settings > Answer model (or by saving an empty key). Like the archive keys, the Keychain item survives app uninstall until cleared there or in Keychain Access.
- Uninstalling Peeknook does not automatically delete archive files. Remove the Conversations folder under the paths above (use the **container** path for the shipped app).

## Third-party services

- **Ollama** (user-installed or user-configured): runs models locally or on a server/endpoint you configure, including optional `:cloud` tags.
- **OpenAI-compatible server** (optional backend, user-installed or user-configured): LM Studio, vLLM, or any `/v1/chat/completions` server you point Peeknook at. Peeknook sends it the same payloads it would send Ollama and nothing else.
- **DuckDuckGo** (opt-in web lookup only): HTML search results.
- **Ollama model catalog proxy** (model library browse only): `https://ollama-models-api.devcomfort.workers.dev`: tag and search metadata from the public Ollama library; not operated by Peeknook and not used during capture inference.

## Contact

[GitHub Issues](https://github.com/glendonC/peeknook/issues): privacy questions and bug reports.

Email: <hello@athledev.com>

## Changes

We may update this policy as features change. The in-app About section links to this document.
