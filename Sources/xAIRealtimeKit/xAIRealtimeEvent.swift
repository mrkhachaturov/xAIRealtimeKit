//
//  xAIRealtimeEvent.swift
//  Typed server -> client events emitted by the xAI Voice Agent API.
//
//  The Voice Agent API is OpenAI-Realtime-compatible. The modeled cases cover
//  every event documented in https://docs.x.ai/docs/voice-agent-api ; a
//  `.unknown(type:jsonText:)` case preserves the raw frame for forward
//  compatibility so callers can decode new server events without losing data.
//

import Foundation

public enum xAIRealtimeEvent: Sendable, Equatable {
    /// `session.created` — initial server greeting after the WebSocket opens.
    case sessionCreated(sessionId: String?)
    /// `session.updated` — your `session.update` was applied.
    case sessionUpdated

    /// `conversation.created` — server allocated a conversation.
    case conversationCreated(conversationId: String?)
    /// `conversation.item.created` / `conversation.item.added` — collapsed into one case.
    case conversationItemAdded(role: String?, itemId: String?)
    /// `conversation.item.input_audio_transcription.completed` — final user transcript.
    case inputTranscriptionCompleted(itemId: String?, transcript: String)

    case speechStarted
    case speechStopped
    case inputAudioBufferCommitted(itemId: String?)
    case inputAudioBufferCleared

    /// `response.created` — assistant begins a turn.
    case responseCreated(responseId: String)
    /// `response.output_audio.delta` / `response.audio.delta` — base64-decoded PCM bytes.
    case audioDelta(responseId: String?, pcm16: Data)
    /// `response.output_audio.done` / `response.audio.done`.
    case audioDone(responseId: String?)
    /// `response.output_audio_transcript.delta` / `response.audio_transcript.delta`.
    case audioTranscriptDelta(responseId: String?, delta: String)
    /// `response.output_audio_transcript.done` / `response.audio_transcript.done`.
    case audioTranscriptDone(responseId: String?)
    /// `response.text.delta` (xAI) / `response.output_text.delta` (OpenAI alias).
    case textDelta(responseId: String?, delta: String)
    /// `response.function_call_arguments.done` — tool/function invocation complete.
    case functionCallArgumentsDone(callId: String, name: String, arguments: String)
    /// `response.done` — turn complete.
    case responseDone(status: String?)

    /// `ping` — server keepalive. Reply with ``xAIRealtimeSession/sendPong(timestamp:)``.
    case ping(timestamp: Int64?)

    /// `error` — server-side issue. Connection may still be open.
    case error(code: String?, message: String)

    /// Any frame whose `type` we don't model. The raw JSON text is preserved so
    /// callers can opt in with their own decoder.
    case unknown(type: String, jsonText: String)
}

extension xAIRealtimeEvent {
    /// Parse a server -> client frame. Exposed for testing.
    public static func decode(text: String) -> xAIRealtimeEvent? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return nil }
        return decode(type: type, json: json, raw: text)
    }

    static func decode(type: String, json: [String: Any], raw: String) -> xAIRealtimeEvent {
        switch type {
        case "session.created":
            let sessionId = (json["session"] as? [String: Any])?["id"] as? String
            return .sessionCreated(sessionId: sessionId)
        case "session.updated":
            return .sessionUpdated
        case "conversation.created":
            let id = (json["conversation"] as? [String: Any])?["id"] as? String
            return .conversationCreated(conversationId: id)
        case "conversation.item.created", "conversation.item.added":
            let item = json["item"] as? [String: Any]
            return .conversationItemAdded(role: item?["role"] as? String, itemId: item?["id"] as? String)
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscriptionCompleted(
                itemId: json["item_id"] as? String,
                transcript: (json["transcript"] as? String) ?? ""
            )
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "input_audio_buffer.committed":
            return .inputAudioBufferCommitted(itemId: json["item_id"] as? String)
        case "input_audio_buffer.cleared":
            return .inputAudioBufferCleared
        case "response.created":
            let id = (json["response"] as? [String: Any])?["id"] as? String ?? ""
            return .responseCreated(responseId: id)
        case "response.output_audio.delta", "response.audio.delta":
            let base64 = (json["delta"] as? String) ?? ""
            let bytes = Data(base64Encoded: base64) ?? Data()
            return .audioDelta(responseId: json["response_id"] as? String, pcm16: bytes)
        case "response.output_audio.done", "response.audio.done":
            return .audioDone(responseId: json["response_id"] as? String)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return .audioTranscriptDelta(
                responseId: json["response_id"] as? String,
                delta: (json["delta"] as? String) ?? ""
            )
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return .audioTranscriptDone(responseId: json["response_id"] as? String)
        case "response.text.delta", "response.output_text.delta":
            return .textDelta(
                responseId: json["response_id"] as? String,
                delta: (json["delta"] as? String) ?? ""
            )
        case "response.function_call_arguments.done":
            return .functionCallArgumentsDone(
                callId: (json["call_id"] as? String) ?? "",
                name: (json["name"] as? String) ?? "",
                arguments: (json["arguments"] as? String) ?? ""
            )
        case "response.done":
            let status = (json["response"] as? [String: Any])?["status"] as? String
            return .responseDone(status: status)
        case "ping":
            let ts: Int64?
            if let v = json["ping_timestamp"] as? Int64 { ts = v }
            else if let v = json["ping_timestamp"] as? Int { ts = Int64(v) }
            else { ts = nil }
            return .ping(timestamp: ts)
        case "error":
            return .error(code: json["code"] as? String, message: (json["message"] as? String) ?? "<unknown>")
        default:
            return .unknown(type: type, jsonText: raw)
        }
    }
}
