import Foundation
import Testing
@testable import xAIRealtimeKit

// MARK: - Auth

@Suite struct xAIRealtimeAuthTests {
    @Test func apiKeyWrapsAsClientSecret() {
        #expect(xAIRealtimeAuth.apiKey("xai-abc").protocolValue == "xai-client-secret.xai-abc")
    }

    @Test func ephemeralAddsPrefixWhenMissing() {
        #expect(xAIRealtimeAuth.ephemeralToken("abc123").protocolValue == "xai-client-secret.abc123")
    }

    @Test func ephemeralPreservesAlreadyPrefixed() {
        let already = "xai-client-secret.long-random-value"
        #expect(xAIRealtimeAuth.ephemeralToken(already).protocolValue == already)
    }
}

// MARK: - URL

@Suite struct xAIRealtimeURLTests {
    @Test func defaultURLPointsAtRealtimeEndpoint() {
        let config = xAIRealtimeSession.Configuration(auth: .apiKey("k"))
        let url = config.makeURL()
        #expect(url.scheme == "wss")
        #expect(url.host == "api.x.ai")
        #expect(url.path == "/v1/realtime")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "model", value: "grok-voice-latest")))
    }

    @Test func emitsExplicitModel() {
        let config = xAIRealtimeSession.Configuration(model: .grokVoiceThinkFast10, auth: .apiKey("k"))
        let url = config.makeURL()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "model", value: "grok-voice-think-fast-1.0")))
    }
}

// MARK: - Audio config

@Suite struct xAIRealtimeAudioConfigTests {
    @Test func defaultsAreMatched24kHzPCM() throws {
        let cfg = xAIRealtimeAudioConfig.defaults
        #expect(cfg.input?.format.type == .pcm)
        #expect(cfg.input?.format.rate == 24000)
        #expect(cfg.output?.format.type == .pcm)
        #expect(cfg.output?.format.rate == 24000)

        let encoded = try JSONEncoder().encode(cfg)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let input = (json["input"] as? [String: Any])?["format"] as? [String: Any]
        #expect(input?["type"] as? String == "audio/pcm")
        #expect(input?["rate"] as? Int == 24000)
    }

    @Test func telephonyCodecsHaveNoSampleRate() throws {
        let format = xAIRealtimeAudioFormat(type: .pcmu, rate: nil)
        let encoded = try JSONEncoder().encode(format)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(json["type"] as? String == "audio/pcmu")
        #expect(json["rate"] == nil)
    }
}

// MARK: - session.update encoder

@Suite struct xAIRealtimeSessionUpdateEncoderTests {
    @Test func minimalConfigEncodesVoiceAndDefaults() throws {
        let frame = try xAIRealtimeOutbound.sessionUpdate(.init(voice: .eve, instructions: "be brief"))
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "session.update")
        let session = json["session"] as! [String: Any]
        #expect(session["voice"] as? String == "eve")
        #expect(session["instructions"] as? String == "be brief")
        let td = session["turn_detection"] as? [String: Any]
        #expect(td?["type"] as? String == "server_vad")
    }

    @Test func customVoiceIdRouteUsesRawString() throws {
        let frame = try xAIRealtimeOutbound.sessionUpdate(.init(customVoiceId: "voice_abc123"))
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        let session = json["session"] as! [String: Any]
        #expect(session["voice"] as? String == "voice_abc123")
    }

    @Test func manualTurnsOmitTurnDetection() throws {
        let frame = try xAIRealtimeOutbound.sessionUpdate(
            .init(voice: .ara, instructions: nil, turnDetection: nil, audio: nil)
        )
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        let session = json["session"] as! [String: Any]
        #expect(session["turn_detection"] == nil)
        #expect(session["audio"] == nil)
    }

    @Test func rawSessionPassthroughWrapsInEnvelope() throws {
        let raw = #"{"voice":"leo","tools":[{"type":"web_search"}]}"#
        let frame = try xAIRealtimeOutbound.sessionUpdate(rawSession: raw)
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "session.update")
        let session = json["session"] as! [String: Any]
        #expect(session["voice"] as? String == "leo")
        let tools = session["tools"] as! [[String: Any]]
        #expect(tools.first?["type"] as? String == "web_search")
    }

    @Test func rawSessionRejectsInvalidJSON() {
        #expect(throws: xAIRealtimeError.self) {
            try xAIRealtimeOutbound.sessionUpdate(rawSession: "not json")
        }
    }
}

// MARK: - Other outbound encoders

@Suite struct xAIRealtimeOutboundEncoderTests {
    @Test func inputAudioAppendBase64Shape() throws {
        let frame = xAIRealtimeOutbound.inputAudioAppend(base64: "AAA=")
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "input_audio_buffer.append")
        #expect(json["audio"] as? String == "AAA=")
    }

    @Test func inputAudioAppendBytesEncodesBase64() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let frame = xAIRealtimeOutbound.inputAudioAppend(bytes: bytes)
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["audio"] as? String == bytes.base64EncodedString())
    }

    @Test func inputAudioCommitAndClear() throws {
        let commit = try JSONSerialization.jsonObject(with: Data(xAIRealtimeOutbound.inputAudioCommit.utf8)) as! [String: Any]
        #expect(commit["type"] as? String == "input_audio_buffer.commit")
        let clear = try JSONSerialization.jsonObject(with: Data(xAIRealtimeOutbound.inputAudioClear.utf8)) as! [String: Any]
        #expect(clear["type"] as? String == "input_audio_buffer.clear")
    }

    @Test func userTextEncodesNestedMessage() throws {
        let frame = try xAIRealtimeOutbound.userText("Hello")
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "conversation.item.create")
        let item = json["item"] as! [String: Any]
        #expect(item["type"] as? String == "message")
        #expect(item["role"] as? String == "user")
        let content = item["content"] as! [[String: Any]]
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "Hello")
    }

    @Test func functionCallOutputEncodesCallId() throws {
        let frame = try xAIRealtimeOutbound.functionCallOutput(callId: "call_42", output: "{\"ok\":true}")
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        let item = json["item"] as! [String: Any]
        #expect(item["type"] as? String == "function_call_output")
        #expect(item["call_id"] as? String == "call_42")
        #expect(item["output"] as? String == "{\"ok\":true}")
    }

    @Test func responseCreateWithoutOptionsIsBare() throws {
        let frame = try xAIRealtimeOutbound.responseCreate()
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "response.create")
        #expect(json.count == 1)
    }

    @Test func responseCreateWithOptionsEncodesModalities() throws {
        let frame = try xAIRealtimeOutbound.responseCreate(options: .textAndAudio)
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        let response = json["response"] as! [String: Any]
        #expect(response["modalities"] as? [String] == ["text", "audio"])
    }

    @Test func pongRoundTripsTimestamp() throws {
        let frame = xAIRealtimeOutbound.pong(timestamp: 1_715_999_999)
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "pong")
        #expect(json["ping_timestamp"] as? Int64 == 1_715_999_999)
    }
}

// MARK: - Inbound event decoder

@Suite struct xAIRealtimeEventDecoderTests {
    @Test func decodesSessionCreatedWithId() {
        let frame = #"{"type":"session.created","session":{"id":"sess_123"}}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .sessionCreated(sessionId: "sess_123"))
    }

    @Test func decodesSessionUpdated() {
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"session.updated"}"#) == .sessionUpdated)
    }

    @Test func decodesConversationCreated() {
        let frame = #"{"type":"conversation.created","conversation":{"id":"conv_42"}}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .conversationCreated(conversationId: "conv_42"))
    }

    @Test func decodesConversationItemAddedAndCreated() {
        let added = #"{"type":"conversation.item.added","item":{"id":"item_1","role":"user"}}"#
        let created = #"{"type":"conversation.item.created","item":{"id":"item_2","role":"assistant"}}"#
        #expect(xAIRealtimeEvent.decode(text: added) == .conversationItemAdded(role: "user", itemId: "item_1"))
        #expect(xAIRealtimeEvent.decode(text: created) == .conversationItemAdded(role: "assistant", itemId: "item_2"))
    }

    @Test func decodesInputTranscriptionCompleted() {
        let frame = #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"hello world"}"#
        #expect(
            xAIRealtimeEvent.decode(text: frame) ==
            .inputTranscriptionCompleted(itemId: "i1", transcript: "hello world")
        )
    }

    @Test func decodesSpeechStartedStoppedAndCommitted() {
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"input_audio_buffer.speech_started"}"#) == .speechStarted)
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"input_audio_buffer.speech_stopped"}"#) == .speechStopped)
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"input_audio_buffer.committed","item_id":"i9"}"#) == .inputAudioBufferCommitted(itemId: "i9"))
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"input_audio_buffer.cleared"}"#) == .inputAudioBufferCleared)
    }

    @Test func decodesResponseCreated() {
        let frame = #"{"type":"response.created","response":{"id":"resp_1"}}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .responseCreated(responseId: "resp_1"))
    }

    @Test func decodesAudioDeltaBase64ToBytes() {
        let payload = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let frame = #"{"type":"response.output_audio.delta","response_id":"r1","delta":"\#(payload.base64EncodedString())"}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .audioDelta(responseId: "r1", pcm16: payload))
    }

    @Test func decodesAudioDeltaAlias() {
        let payload = Data([0x01, 0x02])
        let frame = #"{"type":"response.audio.delta","response_id":"r2","delta":"\#(payload.base64EncodedString())"}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .audioDelta(responseId: "r2", pcm16: payload))
    }

    @Test func decodesAudioDoneBothNames() {
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"response.output_audio.done","response_id":"r"}"#) == .audioDone(responseId: "r"))
        #expect(xAIRealtimeEvent.decode(text: #"{"type":"response.audio.done","response_id":"r"}"#) == .audioDone(responseId: "r"))
    }

    @Test func decodesAudioTranscriptDeltaBothNames() {
        #expect(
            xAIRealtimeEvent.decode(text: #"{"type":"response.output_audio_transcript.delta","response_id":"r","delta":"hi"}"#) ==
            .audioTranscriptDelta(responseId: "r", delta: "hi")
        )
        #expect(
            xAIRealtimeEvent.decode(text: #"{"type":"response.audio_transcript.delta","response_id":"r","delta":"hi"}"#) ==
            .audioTranscriptDelta(responseId: "r", delta: "hi")
        )
    }

    @Test func decodesTextDeltaXAIAndOpenAINames() {
        #expect(
            xAIRealtimeEvent.decode(text: #"{"type":"response.text.delta","response_id":"r","delta":"chunk"}"#) ==
            .textDelta(responseId: "r", delta: "chunk")
        )
        #expect(
            xAIRealtimeEvent.decode(text: #"{"type":"response.output_text.delta","response_id":"r","delta":"chunk"}"#) ==
            .textDelta(responseId: "r", delta: "chunk")
        )
    }

    @Test func decodesFunctionCallArgumentsDone() {
        let frame = #"{"type":"response.function_call_arguments.done","call_id":"call_x","name":"get_weather","arguments":"{\"location\":\"NYC\"}"}"#
        #expect(
            xAIRealtimeEvent.decode(text: frame) ==
            .functionCallArgumentsDone(callId: "call_x", name: "get_weather", arguments: "{\"location\":\"NYC\"}")
        )
    }

    @Test func decodesResponseDone() {
        let frame = #"{"type":"response.done","response":{"status":"completed"}}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .responseDone(status: "completed"))
    }

    @Test func decodesPing() {
        let frame = #"{"type":"ping","ping_timestamp":12345}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .ping(timestamp: 12345))
    }

    @Test func decodesError() {
        let frame = #"{"type":"error","code":"timeout","message":"session too long"}"#
        #expect(xAIRealtimeEvent.decode(text: frame) == .error(code: "timeout", message: "session too long"))
    }

    @Test func passesThroughUnknownTypesWithRawText() {
        let frame = #"{"type":"some.new.event","foo":1}"#
        guard case let .unknown(type, jsonText) = xAIRealtimeEvent.decode(text: frame)! else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "some.new.event")
        #expect(jsonText == frame)
    }

    @Test func rejectsNonJSONAndMissingType() {
        #expect(xAIRealtimeEvent.decode(text: "garbage") == nil)
        #expect(xAIRealtimeEvent.decode(text: #"{"no_type":true}"#) == nil)
    }
}

// MARK: - Error

// MARK: - Client secret (ephemeral mint)

@Suite struct xAIRealtimeClientSecretTests {
    @Test func bodyEncodesExpiresAfterSeconds() throws {
        let data = xAIRealtimeClientSecret.encodeBody(expiresAfterSeconds: 300)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let expires = json["expires_after"] as! [String: Any]
        #expect(expires["seconds"] as? Int == 300)
        #expect(json.count == 1)
    }

    @Test func responseDecodesValueAndExpiresAt() throws {
        let raw = #"{"value":"xai-client-secret.abc123","expires_at":"2026-05-18T04:00:00Z"}"#
        let r = try JSONDecoder().decode(xAIRealtimeClientSecret.Response.self, from: Data(raw.utf8))
        #expect(r.value == "xai-client-secret.abc123")
        #expect(r.expiresAt == "2026-05-18T04:00:00Z")
    }

    @Test func responseValueFlowsIntoEphemeralAuthUntouched() {
        let r = xAIRealtimeClientSecret.Response(value: "xai-client-secret.xyz", expiresAt: "now")
        _ = r.expiresAt   // silence unused-let warning in some toolchains
        #expect(xAIRealtimeAuth.ephemeralToken(r.value).protocolValue == "xai-client-secret.xyz")
    }
}

@Suite struct xAIRealtimeErrorTests {
    @Test func errorDescriptionsAreNonEmpty() {
        let cases: [xAIRealtimeError] = [
            .invalidURL, .missingAuth,
            .http(status: 401, body: "bad key"),
            .server(code: "max_duration", message: "session expired"),
            .encoding("bad payload"), .decoding("bad frame"),
            .canceled
        ]
        for err in cases {
            #expect((err.errorDescription ?? "").isEmpty == false)
        }
    }
}
