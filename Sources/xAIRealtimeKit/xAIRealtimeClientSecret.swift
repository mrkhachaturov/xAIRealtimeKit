//
//  xAIRealtimeClientSecret.swift
//  Mint a short-lived ephemeral token for client-side use of the Voice Agent API.
//
//  POST https://api.x.ai/v1/realtime/client_secrets
//  Body: { "expires_after": { "seconds": <int> } }   // no "session" or
//                                                       "expires_after.anchor"
//  Response: { "value": "xai-client-secret.<random>", "expires_at": "<ISO 8601>" }
//
//  SERVER-SIDE ONLY. Calling this from a shipped client app would defeat the
//  point — the whole reason ephemerals exist is to keep the long-lived API key
//  off the device. Run this on your backend and ship the resulting `value` to
//  iOS/web clients via your own RPC, then authenticate the WebSocket with
//  ``xAIRealtimeAuth/ephemeralToken(_:)``.
//

import Foundation

public enum xAIRealtimeClientSecret {

    public struct Response: Decodable, Sendable, Equatable {
        /// Full prefixed value — `xai-client-secret.<random>` — pass straight
        /// into ``xAIRealtimeAuth/ephemeralToken(_:)``.
        public let value: String
        /// ISO 8601 timestamp at which the ephemeral stops working.
        public let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case value
            case expiresAt = "expires_at"
        }
    }

    /// Mint an ephemeral token. **Run on your server only** — passing the
    /// long-lived API key from a client device defeats the whole point.
    ///
    /// - Parameters:
    ///   - apiKey: your long-lived xAI API key.
    ///   - expiresAfterSeconds: token lifetime. xAI accepts at least 300 s.
    ///   - urlSession: inject a custom session for tests / proxies.
    ///   - baseURL: override the mint endpoint (defaults to xAI production).
    public static func mint(
        apiKey: String,
        expiresAfterSeconds: Int = 300,
        urlSession: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.x.ai/v1/realtime/client_secrets")!
    ) async throws -> Response {
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encodeBody(expiresAfterSeconds: expiresAfterSeconds)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch is CancellationError {
            throw xAIRealtimeError.canceled
        }
        guard let http = response as? HTTPURLResponse else {
            throw xAIRealtimeError.decoding("non-HTTP response from mint endpoint")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw xAIRealtimeError.http(status: http.statusCode, body: String(data: data.prefix(4096), encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw xAIRealtimeError.decoding(String(describing: error))
        }
    }

    /// Build the mint-request body. Exposed for testing.
    public static func encodeBody(expiresAfterSeconds: Int) -> Data {
        let payload: [String: Any] = ["expires_after": ["seconds": expiresAfterSeconds]]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }
}
