//
//  xAIRealtimeError.swift
//

import Foundation

public enum xAIRealtimeError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case missingAuth
    case http(status: Int, body: String?)
    case server(code: String?, message: String)
    case encoding(String)
    case decoding(String)
    case canceled

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid xAI Realtime URL"
        case .missingAuth: return "Missing xAI auth (apiKey or ephemeralToken)"
        case .http(let s, let body): return "xAI Realtime HTTP \(s): \(body ?? "<no body>")"
        case .server(let code, let message): return "xAI Realtime server error [\(code ?? "?")]: \(message)"
        case .encoding(let m): return "xAI Realtime encoding: \(m)"
        case .decoding(let m): return "xAI Realtime decoding: \(m)"
        case .canceled: return "xAI Realtime canceled"
        }
    }
}
