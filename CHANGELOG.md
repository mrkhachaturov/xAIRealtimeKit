# Changelog

## 0.1.0 — initial release

- `xAIRealtimeSession` actor — full-duplex Voice Agent client over `wss://api.x.ai/v1/realtime`
- Auth: `xAIRealtimeAuth.apiKey(_:)` (server-side) and `xAIRealtimeAuth.ephemeralToken(_:)` (client-side, gateway-minted) — both wrapped as `Sec-WebSocket-Protocol: xai-client-secret.<value>` to survive Apple's WebSocket-upgrade header stripping
- Typed model + voice enums: `xAIRealtimeModel` (`grokVoiceLatest`, `grokVoiceThinkFast10`, `grokVoiceFast10`), `xAIRealtimeVoice` (`eve`/`ara`/`rex`/`sal`/`leo`) + raw custom-voice-id route
- Typed session config (`xAIRealtimeSessionConfig`) covering voice / instructions / turn detection / audio formats; raw `session.update` passthrough for tools and other fields
- Typed audio config: `xAIRealtimeAudioCodec` (`audio/pcm`, `audio/pcmu`, `audio/pcma`), `xAIRealtimeAudioFormat`, defaults helper for matched 24 kHz PCM in/out
- Typed turn detection (`xAIRealtimeTurnDetection`) with VAD knobs (threshold, silence duration, prefix padding); omit the struct to use manual turns
- Inbound `xAIRealtimeEvent` enum covering all events the iOS cookbook handles — session lifecycle, conversation items, user speech (`speechStarted`/`speechStopped`/`inputAudioBufferCommitted`), assistant response (audio deltas decoded to `Data`, audio/text transcript deltas, function calls, response done), `ping` keepalive, server errors — plus `.unknown(type:jsonText:)` pass-through for forward compatibility
- Both common naming variants accepted (e.g. `response.output_audio.delta` and `response.audio.delta`; `response.text.delta` and OpenAI's `response.output_text.delta`)
- Outbound helpers as methods on the actor AND as static pure functions in `xAIRealtimeOutbound` (testable, reusable, hot-path-friendly):
  - `updateSession(_:)`
  - `appendInputAudio(base64:)` / `appendInputAudio(bytes:)`
  - `commitInputAudio()` / `clearInputAudio()`
  - `sendUserText(_:)`
  - `createResponse(options:)`
  - `sendFunctionCallOutput(callId:output:)`
  - `sendPong(timestamp:)`
  - `sendRaw(jsonString:)`
- Structured `xAIRealtimeError`
- Actor-based concurrency, `Sendable` everywhere, zero external dependencies
- `xAIRealtimeClientSecret.mint(apiKey:expiresAfterSeconds:)` — server-side helper that calls `POST /v1/realtime/client_secrets` to mint ephemerals (the `value` flows straight into `xAIRealtimeAuth.ephemeralToken(_:)`)
- Swift Testing suite (42 tests) covering auth wrapping, URL building, audio config encoding, all outbound encoders, full inbound event decoder coverage (including OpenAI-style aliases and `.unknown` pass-through), and the ephemeral mint body/response shape

## Roadmap

- `v0.2.0` — typed `xAIRealtimeTool` enum (`file_search`, `web_search`, `x_search`, `mcp`, `function`) wired into `xAIRealtimeSessionConfig` so tools don't require the raw-JSON escape hatch
- `v0.3.0` — `AVAudioEngine` mic-tap helper that streams base64 PCM directly into the session (off the actor's hot path)
