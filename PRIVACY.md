# Peeknook privacy policy

Last updated: 2026-06-06

Peeknook is a local-first practice copilot for the MacBook notch. This policy describes what the app processes, what stays on your Mac, and what can leave your Mac when you opt in.

## Summary

- Peeknook does **not** run cloud inference.
- Capture happens **only when you press the capture hotkey** (default ⌘⇧P).
- Conversation archive and web lookup are **off by default**.
- Peeknook does **not** include analytics or crash telemetry in the current release.

## What Peeknook processes

### Screenshots (required for vision answers)

When you capture, Peeknook takes a screenshot of the window or display under your cursor and sends it to your configured Ollama instance for analysis. Screenshots exist in memory for the active chat.

### Optional selected text

If you grant Accessibility permission, Peeknook may read selected text from the focused field to supplement the screenshot. This is optional.

### Prompts and answers

Your questions and the model's answers are kept in the active conversation thread in memory. If you enable **Save conversations**, the full thread (screenshots included) is written to local files under:

`~/Library/Application Support/Peeknook/Conversations/`

### Usage stats

Peeknook records local usage metadata (capture counts, token estimates, timing) in your module UserDefaults suite. This does not include screenshot pixels or conversation text. You can reset stats in Settings → Data.

## What stays on your Mac by default

- Inference defaults to `http://127.0.0.1:11434` (local Ollama).
- Usage stats stay in local preferences.
- Conversation archive is **off by default**.

## When data can leave your Mac

You control the following opt-in features:

| Feature | Default | What leaves your Mac |
|---------|---------|----------------------|
| Web lookup | Off | Search query to DuckDuckGo HTML (`html.duckduckgo.com`) |
| Remote Ollama URL | Off (local default) | Screenshots and chat sent to the server you configure |
| Model library catalog browse | On when used | Tag metadata requests to the Ollama catalog API |
| Save conversations | Off | Nothing leaves your Mac; files stay local |
| Voice input | Off | On-device speech recognition (Microphone + Speech Recognition permissions) |
| Read answers aloud | Off | On-device text-to-speech; no network |

## Data retention and deletion

- **New chat** deletes the active archived thread when Save conversations is on.
- Turning **Save conversations** off purges the entire archive.
- **Reset stats** clears usage metadata in Settings → Data.
- Uninstalling Peeknook does not automatically delete `~/Library/Application Support/Peeknook/`. Remove that folder to wipe local archive files.

## Third-party services

- **Ollama** (user-installed): runs models locally or on a server you configure.
- **DuckDuckGo** (opt-in web lookup only): HTML search results.
- **Ollama catalog API** (model library browse): model tag metadata, not your screenshots.

## Contact

Report privacy questions or issues on GitHub: https://github.com/glendonC/peeknook/issues

## Changes

We may update this policy as features change. The in-app About section links to this document.
