# Security Policy

## Supported versions

Peeknook is pre-1.0. Security fixes land on `main` and the next tagged release. Older tags are not
patched.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's private vulnerability reporting:
<https://github.com/glendonC/peeknook/security/advisories/new>

Or email <hello@athledev.com>.

Include:

- a description of the issue,
- a minimal reproduction or proof of concept,
- the affected version (commit SHA or tag),
- any disclosure timeline you have in mind.

You'll get an acknowledgement within a few days. Confirmed issues are fixed on a private branch,
released, and credited in the release notes (unless you ask to stay anonymous).

## Scope notes

Peeknook is a local-first macOS app. It captures the screen, a window, or the camera only when you
trigger it, and sends captures to the inference endpoint you configure. The realistic risk surface:

- **Capture.** Captures are private user data — a screenshot can contain anything on screen. Capture
  is user-triggered only; there is no ambient or background recording. See [PRIVACY.md](PRIVACY.md).
- **Inference endpoint.** Local-first by default (local Ollama). A remote Ollama URL and Ollama
  `:cloud` tags are opt-in and HTTPS-gated — plain HTTP to a non-loopback host is rejected unless you
  enable "Allow insecure HTTP" (`OllamaURLPolicy`). Bugs that bypass this gate are in scope.
- **Secrets in captures / queries.** Sent text is redacted for likely secrets on remote/cloud egress,
  and opt-in web lookup skips queries that look like secrets or password-manager windows
  (`SensitiveTextHeuristics`). Gaps here are in scope.
- **Credential storage.** Optional inference API keys are stored in the macOS Keychain, never in
  settings files.
- **Conversation archive.** Opt-in and off by default; when enabled, chats are encrypted on disk.

Packaging concerns (signing / notarization of a given build) are handled per release and are not a
code vulnerability.
