# xAIRealtimeKit — xAI Grok Voice Agent on tap, SwiftPM-friendly, full-duplex.

Swift client for the [xAI Grok Voice Agent API](https://docs.x.ai/docs/voice-agent-api) on Apple platforms (iOS/macOS).

![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20%7C%20macOS%2015%2B-blue)
![License](https://img.shields.io/badge/License-MIT-green)

> Brand convention: the brand is **xAI** (lowercase `x`, uppercase `AI`).
> All public types follow suit — `xAIRealtimeSession`, `xAIRealtimeAuth`,
> `xAIRealtimeEvent`, etc. Intentional violation of the Swift API Design
> Guidelines in favor of brand fidelity. Don't "fix" it.

## What's Included

- `xAIRealtimeSession` actor — full-duplex WebSocket against `wss://api.x.ai/v1/realtime`
- Both auth modes:
  - `xAIRealtimeAuth.apiKey(_:)` — server-side
  - `xAIRealtimeAuth.ephemeralToken(_:)` — client-side, minted via your gateway
- Server-side ephemeral mint helper: `xAIRealtimeClientSecret.mint(apiKey:expiresAfterSeconds:)` (calls `POST /v1/realtime/client_secrets`)
- Typed session config (voice / instructions / turn detection / audio formats) + raw `session.update` escape hatch for tools
- Typed inbound `xAIRealtimeEvent` enum covering session, conversation, speech, response (audio / text / transcript / function calls), `ping`, and server errors — plus `.unknown(type:jsonText:)` so forward-compatibility doesn't drop data
- Both OpenAI and xAI event-name variants recognised (e.g. `response.text.delta` ⇄ `response.output_text.delta`)
- Static outbound encoders (`xAIRealtimeOutbound.*`) for the hot path — build JSON once and reuse across mic frames
- Actor-based concurrency, `Sendable` everywhere, zero external dependencies

## Requirements

- Swift 6.2 (SwiftPM `swift-tools-version: 6.2`)
- iOS 18+
- macOS 15+

## Install (Swift Package Manager)

### Xcode

**File > Add Package Dependencies...** and enter:
```
https://github.com/mrkhachaturov/xAIRealtimeKit.git
```

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/mrkhachaturov/xAIRealtimeKit.git", from: "0.1.0"),
]
```

## Auth — read this first

The xAI Voice Agent API has two auth modes; both are wrapped as
`Sec-WebSocket-Protocol: xai-client-secret.<value>` because
`URLSessionWebSocketTask` strips the `Authorization` header during the HTTP→WS
upgrade on Apple platforms (same workaround the xAI iOS cookbook uses).

| Mode | Where to use | Notes |
|------|-------------|-------|
| `xAIRealtimeAuth.apiKey(_:)` | Server-side only | The whole reason ephemerals exist is to keep this off client devices |
| `xAIRealtimeAuth.ephemeralToken(_:)` | iOS / web | Mint server-side, ship to client via your gateway RPC |

### Minting an ephemeral (server-side)

```swift
let secret = try await xAIRealtimeClientSecret.mint(
    apiKey: ProcessInfo.processInfo.environment["XAI_API_KEY"]!,
    expiresAfterSeconds: 300        // xAI minimum
)
print(secret.value)        // "xai-client-secret.<random>" — ship this to the client
print(secret.expiresAt)    // ISO 8601 timestamp
```

The OpenClaw gateway's `createBrowserSession` already does this and returns
the ephemeral via the `talk.client.create` RPC — use that on the device:

```swift
// iOS side: receive the ephemeral via your gateway RPC, then:
let auth = xAIRealtimeAuth.ephemeralToken(rpcResponse.clientSecret)
```

## Quick Start

```swift
import xAIRealtimeKit

let session = try await xAIRealtimeSession.open(
    configuration: .init(
        model: .grokVoiceLatest,
        auth: .ephemeralToken("xai-client-secret.<from-gateway>")
    )
)

// Configure voice + server-VAD + matched 24 kHz PCM I/O.
try await session.updateSession(.init(
    voice: .eve,
    instructions: "You are a helpful, brief assistant.",
    turnDetection: .serverVADDefault,
    audio: .defaults
))

// Stream mic audio (base64 PCM16, 24 kHz from your AVAudioEngine tap):
Task {
    for await pcmBase64 in micBase64Stream {
        try await session.appendInputAudio(base64: pcmBase64)
    }
}

// React to server events:
for try await event in session.events {
    switch event {
    case .sessionCreated, .sessionUpdated, .conversationCreated:
        break
    case .speechStarted:
        ui.interruptAssistant()
    case .audioDelta(_, let pcm):
        player.enqueue(pcm)
    case .audioTranscriptDelta(_, let text):
        ui.appendAssistantTranscript(text)
    case .responseDone:
        ui.finishAssistantBubble()
    case .functionCallArgumentsDone(let callId, let name, let arguments):
        await handleTool(name: name, callId: callId, arguments: arguments, in: session)
    case .ping(let ts):
        if let ts { try? await session.sendPong(timestamp: ts) }
    case .error(let code, let message):
        ui.showError(code: code, message: message)
    default:
        break
    }
}

await session.close()
```

## Hot-path audio sending

The actor-isolated `appendInputAudio(base64:)` is fine for moderate rates, but
if you're pushing 24 kHz PCM16 from a mic tap and want to skip the actor hop,
build the JSON yourself with the static encoder and call `sendRaw` directly:

```swift
let frame = xAIRealtimeOutbound.inputAudioAppend(base64: chunkBase64)
try await session.sendRaw(jsonString: frame)
```

Or, mirroring the cookbook, interpolate it inline to avoid one extra
allocation per mic frame:

```swift
let json = #"{"type":"input_audio_buffer.append","audio":"\#(chunkBase64)"}"#
try await session.sendRaw(jsonString: json)
```

## Tool/function calling

The model emits `response.function_call_arguments.done` when it decides to
invoke a tool. Reply with the output and (after the current audio playback
finishes — see "Audio overlap" below) request a continuation.

```swift
case .functionCallArgumentsDone(let callId, let name, let arguments):
    let result = try await runTool(name: name, arguments: arguments)

    try await session.sendFunctionCallOutput(callId: callId, output: result)

    // IMPORTANT: wait for audio playback to drain before asking for more.
    await waitForAudioPlaybackToFinish()
    try await session.createResponse(options: .textAndAudio)
```

### Parallel tool calls

If the model fires multiple `functionCallArgumentsDone` events in a row, send
**all** their outputs via `sendFunctionCallOutput` before calling
`createResponse` once. Premature `createResponse` runs without the missing
tool context.

## Tools at session-config time (raw passthrough)

`xAIRealtimeSessionConfig` doesn't model tools in v0.1.0. Use the raw
escape hatch:

```swift
let rawSession = #"""
{
  "voice": "eve",
  "instructions": "You are a helpful assistant.",
  "turn_detection": { "type": "server_vad" },
  "tools": [
    { "type": "web_search" },
    {
      "type": "function",
      "name": "get_weather",
      "description": "Get current weather for a location",
      "parameters": {
        "type": "object",
        "properties": { "location": { "type": "string" } },
        "required": ["location"]
      }
    }
  ]
}
"""#
let frame = try xAIRealtimeOutbound.sessionUpdate(rawSession: rawSession)
try await session.sendRaw(jsonString: frame)
```

A typed `Tool` enum is on the v0.2.0 roadmap.

## Audio overlap during tool calls

Per the xAI docs, when the model invokes a tool the server flushes all audio
deltas first, then `response.done` + `function_call_arguments.done`. If you
immediately send the function output AND `response.create`, the server starts
the next response while the client is still playing the previous one →
overlapping audio.

**Recommended sequence:**

1. Receive `audioDelta` / `audioTranscriptDelta` for the current turn
2. Receive `functionCallArgumentsDone` → execute the tool
3. Send `sendFunctionCallOutput`
4. **Wait for current audio playback to drain**
5. Then `createResponse`

Show a "thinking" indicator during step 4 so the gap feels intentional.

## Voices

`xAIRealtimeVoice`: `.eve` (default), `.ara`, `.rex`, `.sal`, `.leo` — same
voice pool as the TTS REST API for the multilingual set. For a cloned voice,
use `xAIRealtimeSessionConfig(customVoiceId: "voice_abc123", …)`.

## Languages

The model auto-detects the input language and responds in kind. No language
parameter is sent — just speak. The xAI docs list 20+ supported languages.

## Error handling

```swift
do {
    let session = try await xAIRealtimeSession.open(configuration: …)
    for try await event in session.events { … }
} catch let error as xAIRealtimeError {
    switch error {
    case .http(let status, _) where status == 401:
        // Ephemeral expired — re-mint via gateway and reconnect
        break
    default:
        print("realtime: \(error.errorDescription ?? "?")")
    }
}
```

Server-emitted errors arrive as `xAIRealtimeEvent.error(code:message:)`. The
cookbook treats `code == "timeout"` or `"max_duration"` as terminal — close
the session and let the user start a new one.

## Best practices (from the xAI docs)

- **Parallel init** — kick off the WebSocket connect and mic capture *together*; don't wait for `session.created`
- **Match input/output to 24 kHz PCM** (`xAIRealtimeAudioConfig.defaults`) so the server doesn't resample
- **Stream audio deltas to the speaker instantly** — don't buffer the whole response
- **Enable `server_vad`** for natural barge-in (default in `xAIRealtimeTurnDetection.serverVADDefault`)
- **Reconnect with backoff** on WS drops; keep buffering mic audio so you don't drop the start of the next utterance
- **Reply to `ping`** with `sendPong(timestamp:)` so the server doesn't kill the connection

## Contributing

Contributions welcome:

1. Fork the repo
2. Create a feature branch
3. Add tests
4. Ensure `swift test` passes
5. Submit a PR

### Development

```bash
swift build
swift test
```

### Guidelines

- Follow the existing brand-cased naming (`xAI…`)
- Keep zero external dependencies
- Maintain `Sendable` conformance under strict concurrency
- Add tests for new features
- Update `CHANGELOG.md`

## License

MIT — see [LICENSE](LICENSE) for details.

## Related

- [xAITTSKit](https://github.com/mrkhachaturov/xAITTSKit) — one-shot and streaming TTS (`/v1/tts`)
- [xAISTTKit](https://github.com/mrkhachaturov/xAISTTKit) — one-shot and streaming STT (`/v1/stt`)
- xAI cookbook: [iOS VoiceTesterApp/VoiceAgent](https://github.com/xai-org/xai-cookbook/tree/main/iOS/VoiceTesterApp/VoiceTesterApp/VoiceAgent)
