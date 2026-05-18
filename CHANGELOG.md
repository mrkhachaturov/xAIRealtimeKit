# Changelog

## 0.2.1 — auto-pong, nonisolated audio helpers, drain-without-polling

- `xAIRealtimeSession.Configuration.autoPong` (default `true`) — the receive loop now replies to server `ping` events with a matching `pong` before yielding the `.ping` to the consumer, so a slow consumer can't starve the server's keepalive budget. Set `false` to drive keepalive yourself.
- Drop `@MainActor` from `xAIRealtimeAudioInputTap.install` / `stop` / `finish` and `xAIRealtimeAudioOutputPlayer.attach` / `start` / `play` / `interrupt` / `stop`. Callable from any isolation domain, matching `AVAudioEngine`'s own contract — no forced main-thread hop when bootstrapping audio off-main.
- `xAIRealtimeAudioOutputPlayer.waitForPlaybackToDrain()` is now backed by `CheckedContinuation` waiters resumed from the `.dataPlayedBack` callback. No polling, no `pollIntervalMillis` knob. `interrupt()` and `stop()` also wake pending waiters so they don't hang.
- `play(base64:)` doc-comment clarified — kept as a convenience for callers using `sendRaw(jsonString:)` who bypass the typed event decoder; iterators of `events` should use `play(pcm16Bytes:)` since `.audioDelta` already delivers decoded bytes.

## 0.2.0 — typed tools, audio helpers, ephemeral-expired signal

- Add typed `xAIRealtimeTool` enum covering all five documented tool types — `fileSearch(vectorStoreIds:maxNumResults:)`, `webSearch`, `xSearch(allowedXHandles:)`, `mcp(MCPConfig)`, `function(name:description:parametersJSON:)` — with a `toAny()` renderer that validates function `parametersJSON` at encode time
- Add `xAIRealtimeOutbound.sessionUpdate(_:tools:)` and `xAIRealtimeSession.updateSession(_:tools:)` overloads that merge a typed `xAIRealtimeSessionConfig` with a `[xAIRealtimeTool]`
- Add `xAIRealtimeError.ephemeralExpired` case, raised automatically when the server closes the WebSocket with code 4401 — callers can drive a mint-and-reconnect loop without poking at `URLError` internals
- Add `xAIRealtimeAudioInputTap` — installs a tap on `AVAudioEngine.inputNode`, converts to 24 kHz mono PCM16 via `AVAudioConverter`, emits chunks through `pcm16Chunks: AsyncStream<Data>` (drop straight into `appendInputAudio(bytes:)`) and rolling RMS through `rmsLevels` for UI metering
- Add `xAIRealtimeAudioOutputPlayer` — attaches an `AVAudioPlayerNode` to an engine, decodes base64 PCM16 deltas to playback, and exposes `waitForPlaybackToDrain()` so callers can implement the recommended tool-call audio gating (send `function_call_output` → await playback drain → `createResponse`)
- 11 new tests covering tool encoding (all five types, optional-field omission, function-parameter JSON validation), `session.update`-with-tools merging, and the `ephemeralExpired` error description (64 total)

## 0.1.0 — initial release

- `xAIRealtimeSession` actor — full-duplex Voice Agent client over `wss://api.x.ai/v1/realtime`
- Auth: `xAIRealtimeAuth.apiKey(_:)` (server-side) and `xAIRealtimeAuth.ephemeralToken(_:)` (client-side), both wrapped as `Sec-WebSocket-Protocol: xai-client-secret.<value>` to survive Apple's WebSocket-upgrade header stripping
- Typed model + voice enums; typed session config covering voice / instructions / turn detection / audio formats; raw `session.update` passthrough for unknown fields
- Typed audio config (`audio/pcm`, `audio/pcmu`, `audio/pcma`) with defaults helper for matched 24 kHz PCM in/out
- Typed turn detection with VAD knobs (threshold, silence_duration_ms, prefix_padding_ms); omit to use manual turns
- Inbound `xAIRealtimeEvent` enum covering session, conversation, speech, response (audio / text / transcript / function calls), `ping`, and server errors — plus `.unknown(type:jsonText:)` pass-through
- Both common naming variants accepted (`response.text.delta` ⇄ `response.output_text.delta`, `response.output_audio.delta` ⇄ `response.audio.delta`)
- Static outbound encoders in `xAIRealtimeOutbound` for the hot path
- `xAIRealtimeClientSecret.mint(apiKey:expiresAfterSeconds:)` — server-side helper around `POST /v1/realtime/client_secrets`
- Structured `xAIRealtimeError`, actor-based concurrency, zero external dependencies
