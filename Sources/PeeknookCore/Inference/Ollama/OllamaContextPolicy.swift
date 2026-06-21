// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Ollama context window (`num_ctx`) Peeknook requests for every model-loading call.
///
/// Ollama defaults `num_ctx` to 4096 when the request omits it, regardless of what the model
/// actually supports. A single capture's image tokens plus the system prompt routinely exceed
/// that, so the call fails with `exceed_context_size_error` ("4309 exceeds 4096"). Gemma 4
/// supports 128K, but the resident KV cache scales with `num_ctx`, and a multi-GB vision model is
/// already the dominant memory cost on a RAM-tight Mac. So we request a sensible window with real
/// headroom over a typical capture, scaled by the same RAM tiers the rest of the Ollama policy
/// uses, not the full 128K.
///
/// The value must be identical across the answer stream, the follow-up pass, and the warm-up call:
/// Ollama keys a loaded model partly by `num_ctx`, so a warm-up at one size followed by an answer
/// at another would silently reload the weights (a fresh cold start), defeating the warm window.
///
/// Pure (no global reads) so the mapping is unit-testable; `recommended()` reads real RAM once.
public enum OllamaContextPolicy {
    /// `num_ctx` in tokens for this RAM tier. Mirrors ``OllamaKeepAlivePolicy``'s 24/48 GB tiers
    /// (both are RAM-headroom policies for the same resident model): tight Macs get a modest window
    /// with clear headroom over a single capture; roomier Macs can hold longer multi-capture chats.
    public static func contextTokens(forPhysicalMemoryGB gb: Int) -> Int {
        if gb < 24 {
            return 8_192        // tight RAM (e2b tier): ~2x a typical capture, no thrash
        } else if gb < 48 {
            return 16_384       // mid tier: room for several captures in one chat
        } else {
            return 32_768       // ample RAM: long multi-capture chats stay in context
        }
    }

    public static func recommended() -> Int {
        contextTokens(forPhysicalMemoryGB: SystemProfile.current().physicalMemoryGB)
    }
}
