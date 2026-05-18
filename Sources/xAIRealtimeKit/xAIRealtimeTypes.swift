//
//  xAIRealtimeTypes.swift
//  Public type-safe enums and Codable payloads for the xAI Voice Agent API.
//  Source: https://docs.x.ai/docs/voice-agent-api
//

import Foundation

// MARK: - Model

/// xAI Grok voice models. `grokVoiceLatest` always points to the newest model.
public enum xAIRealtimeModel: String, Sendable, CaseIterable {
    case grokVoiceLatest = "grok-voice-latest"
    case grokVoiceThinkFast10 = "grok-voice-think-fast-1.0"
    /// Legacy, deprecated upstream — kept for callers still pinned to it.
    case grokVoiceFast10 = "grok-voice-fast-1.0"
}

// MARK: - Voice

/// Built-in voices documented for the Voice Agent API. Custom (cloned) voice IDs
/// are passed as raw strings via the `voice` field directly.
public enum xAIRealtimeVoice: String, Sendable, CaseIterable {
    case eve, ara, rex, sal, leo
}

// MARK: - Auth

/// Two auth modes per the xAI docs. `apiKey` is server-only — for client apps
/// (iOS, browser) mint an ephemeral server-side via
/// ``xAIRealtimeClientSecret/mint(apiKey:expiresAfterSeconds:urlSession:baseURL:)``
/// and pass the resulting `value` as `.ephemeralToken`.
public enum xAIRealtimeAuth: Sendable, Equatable {
    /// Raw xAI API key. Server-only — exposes the key on the device.
    case apiKey(String)
    /// Ephemeral client secret. Either the raw random portion (we'll prepend
    /// the `xai-client-secret.` namespace) or the full prefixed string (we'll
    /// leave it untouched).
    case ephemeralToken(String)

    /// Final string to pass as `Sec-WebSocket-Protocol`. Used by both auth
    /// modes on Apple platforms because `URLSessionWebSocketTask` strips the
    /// `Authorization` header during the HTTP→WS upgrade.
    public var protocolValue: String {
        switch self {
        case .apiKey(let key):
            return "xai-client-secret.\(key)"
        case .ephemeralToken(let token):
            if token.hasPrefix("xai-client-secret.") { return token }
            return "xai-client-secret.\(token)"
        }
    }
}

// MARK: - Audio config

public enum xAIRealtimeAudioCodec: String, Codable, Sendable, Equatable {
    case pcm = "audio/pcm"
    /// G.711 μ-law (8 kHz fixed)
    case pcmu = "audio/pcmu"
    /// G.711 A-law (8 kHz fixed)
    case pcma = "audio/pcma"
}

public struct xAIRealtimeAudioFormat: Codable, Sendable, Equatable {
    public var type: xAIRealtimeAudioCodec
    /// Only meaningful for `audio/pcm`. Allowed values: 8000, 16000, 22050,
    /// 24000 (default), 32000, 44100, 48000.
    public var rate: Int?

    public init(type: xAIRealtimeAudioCodec = .pcm, rate: Int? = 24000) {
        self.type = type
        self.rate = rate
    }
}

public struct xAIRealtimeAudioIO: Codable, Sendable, Equatable {
    public var format: xAIRealtimeAudioFormat
    public init(format: xAIRealtimeAudioFormat) { self.format = format }
}

public struct xAIRealtimeAudioConfig: Codable, Sendable, Equatable {
    public var input: xAIRealtimeAudioIO?
    public var output: xAIRealtimeAudioIO?

    public init(input: xAIRealtimeAudioIO? = nil, output: xAIRealtimeAudioIO? = nil) {
        self.input = input
        self.output = output
    }

    /// Matched 24 kHz PCM16 for input and output (xAI's defaults).
    public static let defaults = xAIRealtimeAudioConfig(
        input: .init(format: .init(type: .pcm, rate: 24000)),
        output: .init(format: .init(type: .pcm, rate: 24000))
    )
}

// MARK: - Turn detection

public struct xAIRealtimeTurnDetection: Codable, Sendable, Equatable {
    /// Currently only `server_vad` is supported. Omit the whole struct from
    /// the session to use manual turns (caller controls `commitInputAudio`).
    public var type: String
    public var threshold: Double?
    public var silenceDurationMs: Int?
    public var prefixPaddingMs: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case threshold
        case silenceDurationMs = "silence_duration_ms"
        case prefixPaddingMs = "prefix_padding_ms"
    }

    public init(
        type: String = "server_vad",
        threshold: Double? = nil,
        silenceDurationMs: Int? = nil,
        prefixPaddingMs: Int? = nil
    ) {
        self.type = type
        self.threshold = threshold
        self.silenceDurationMs = silenceDurationMs
        self.prefixPaddingMs = prefixPaddingMs
    }

    public static let serverVADDefault = xAIRealtimeTurnDetection(type: "server_vad")
}

// MARK: - Session update (subset)

/// Subset of the `session.update` payload covering voice, instructions, turn
/// detection, and audio formats. For tools and other less common fields use
/// ``xAIRealtimeSession/sendRaw(jsonString:)`` directly — typed wrappers can be
/// added in later versions without breaking this struct.
public struct xAIRealtimeSessionConfig: Codable, Sendable, Equatable {
    public var voice: String?
    public var instructions: String?
    public var turnDetection: xAIRealtimeTurnDetection?
    public var audio: xAIRealtimeAudioConfig?

    enum CodingKeys: String, CodingKey {
        case voice, instructions
        case turnDetection = "turn_detection"
        case audio
    }

    public init(
        voice: xAIRealtimeVoice? = nil,
        instructions: String? = nil,
        turnDetection: xAIRealtimeTurnDetection? = .serverVADDefault,
        audio: xAIRealtimeAudioConfig? = .defaults
    ) {
        self.voice = voice?.rawValue
        self.instructions = instructions
        self.turnDetection = turnDetection
        self.audio = audio
    }

    /// Build a config using a raw custom voice ID (cloned voice).
    public init(
        customVoiceId: String,
        instructions: String? = nil,
        turnDetection: xAIRealtimeTurnDetection? = .serverVADDefault,
        audio: xAIRealtimeAudioConfig? = .defaults
    ) {
        self.voice = customVoiceId
        self.instructions = instructions
        self.turnDetection = turnDetection
        self.audio = audio
    }
}

// MARK: - Response create options

public struct xAIRealtimeResponseCreateOptions: Codable, Sendable, Equatable {
    /// `["text"]`, `["audio"]`, or `["text", "audio"]`. Omit to use server defaults.
    public var modalities: [String]?
    public init(modalities: [String]? = nil) { self.modalities = modalities }

    public static let textAndAudio = xAIRealtimeResponseCreateOptions(modalities: ["text", "audio"])
}
