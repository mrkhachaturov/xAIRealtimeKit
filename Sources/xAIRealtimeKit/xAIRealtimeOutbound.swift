//
//  xAIRealtimeOutbound.swift
//  Pure-function encoders for the client -> server frames used by
//  ``xAIRealtimeSession``. Exposed publicly (and used by the test suite) so
//  callers can build their own send paths if they need finer control than the
//  session helpers offer.
//

import Foundation

public enum xAIRealtimeOutbound {

    // MARK: - session.update

    /// Build a `session.update` frame from a typed config. Throws if the typed
    /// payload fails to encode (which can only happen if Foundation's
    /// `JSONEncoder` itself fails — practically never).
    public static func sessionUpdate(_ config: xAIRealtimeSessionConfig) throws -> String {
        let envelope = SessionUpdateEnvelope(type: "session.update", session: config)
        return try jsonString(envelope)
    }

    /// Build a `session.update` from a raw dictionary body — for fields not
    /// covered by ``xAIRealtimeSessionConfig``.
    public static func sessionUpdate(rawSession json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data)
        else { throw xAIRealtimeError.encoding("rawSession must be valid JSON") }
        return #"{"type":"session.update","session":"# + json + "}"
    }

    /// Build a `session.update` from a typed config plus a list of typed
    /// `xAIRealtimeTool` definitions. The two payloads are merged so callers
    /// don't have to choose between typed config and tool support.
    public static func sessionUpdate(_ config: xAIRealtimeSessionConfig, tools: [xAIRealtimeTool]) throws -> String {
        let configData: Data
        do {
            let encoder = JSONEncoder()
            configData = try encoder.encode(config)
        } catch {
            throw xAIRealtimeError.encoding(String(describing: error))
        }
        var sessionDict = ((try? JSONSerialization.jsonObject(with: configData)) as? [String: Any]) ?? [:]
        if !tools.isEmpty {
            sessionDict["tools"] = try tools.map { try $0.toAny() }
        }
        let envelope: [String: Any] = ["type": "session.update", "session": sessionDict]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { throw xAIRealtimeError.encoding("could not serialize session.update with tools") }
        return s
    }

    // MARK: - input_audio_buffer.*

    /// Append base64-encoded PCM (or μ-law/A-law per the session's `audio.input.format`).
    public static func inputAudioAppend(base64: String) -> String {
        #"{"audio":""# + base64 + #"","type":"input_audio_buffer.append"}"#
    }

    /// Append raw bytes — encoded to base64 internally.
    public static func inputAudioAppend(bytes: Data) -> String {
        inputAudioAppend(base64: bytes.base64EncodedString())
    }

    public static let inputAudioCommit: String = #"{"type":"input_audio_buffer.commit"}"#
    public static let inputAudioClear: String = #"{"type":"input_audio_buffer.clear"}"#

    // MARK: - conversation.item.create (user text)

    /// Create a user-text conversation item:
    /// `{ "type": "conversation.item.create", "item": { "type": "message",
    ///    "role": "user", "content": [{ "type": "input_text", "text": "..." }] } }`
    public static func userText(_ text: String) throws -> String {
        let item = UserTextItem(
            type: "conversation.item.create",
            item: UserTextItem.Item(
                type: "message",
                role: "user",
                content: [UserTextItem.Content(type: "input_text", text: text)]
            )
        )
        return try jsonString(item)
    }

    /// Send a function call result back to the server:
    /// `{ "type": "conversation.item.create", "item": { "type": "function_call_output",
    ///    "call_id": "...", "output": "..." } }`
    public static func functionCallOutput(callId: String, output: String) throws -> String {
        let payload = FunctionCallOutput(
            type: "conversation.item.create",
            item: FunctionCallOutput.Item(type: "function_call_output", callId: callId, output: output)
        )
        return try jsonString(payload)
    }

    // MARK: - response.create

    public static func responseCreate(options: xAIRealtimeResponseCreateOptions? = nil) throws -> String {
        if let options {
            let envelope = ResponseCreateEnvelope(type: "response.create", response: options)
            return try jsonString(envelope)
        }
        return #"{"type":"response.create"}"#
    }

    // MARK: - ping / pong

    public static func pong(timestamp: Int64) -> String {
        #"{"ping_timestamp":\#(timestamp),"type":"pong"}"#
    }

    // MARK: - Internals

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw xAIRealtimeError.encoding(String(describing: error))
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw xAIRealtimeError.encoding("non-utf8 JSON output")
        }
        return s
    }

    // MARK: - Codable envelopes

    private struct SessionUpdateEnvelope: Encodable {
        let type: String
        let session: xAIRealtimeSessionConfig
    }

    private struct ResponseCreateEnvelope: Encodable {
        let type: String
        let response: xAIRealtimeResponseCreateOptions
    }

    private struct UserTextItem: Encodable {
        let type: String
        let item: Item
        struct Item: Encodable {
            let type: String
            let role: String
            let content: [Content]
        }
        struct Content: Encodable {
            let type: String
            let text: String
        }
    }

    private struct FunctionCallOutput: Encodable {
        let type: String
        let item: Item
        struct Item: Encodable {
            let type: String
            let callId: String
            let output: String
            enum CodingKeys: String, CodingKey {
                case type
                case callId = "call_id"
                case output
            }
        }
    }
}
