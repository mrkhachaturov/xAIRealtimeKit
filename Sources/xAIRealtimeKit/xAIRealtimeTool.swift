//
//  xAIRealtimeTool.swift
//  Typed Voice Agent tool definitions. The xAI realtime API supports five tool
//  types per the docs: `file_search`, `web_search`, `x_search`, `mcp`, and
//  `function`. They go into `session.update.session.tools`.
//

import Foundation

public enum xAIRealtimeTool: Sendable, Equatable {
    /// Collections (vector store) search.
    case fileSearch(vectorStoreIds: [String], maxNumResults: Int? = nil)
    /// Web search — no configuration.
    case webSearch
    /// X (Twitter) search; optionally restrict to specific handles.
    case xSearch(allowedXHandles: [String]? = nil)
    /// Remote MCP server.
    case mcp(MCPConfig)
    /// Custom function tool. `parametersJSON` must be a JSON Schema object
    /// (validated at encode time).
    case function(name: String, description: String? = nil, parametersJSON: String)

    public struct MCPConfig: Sendable, Equatable {
        public var serverUrl: String
        public var serverLabel: String
        public var serverDescription: String?
        public var allowedTools: [String]?
        /// Sent verbatim as the `Authorization` header on requests to the MCP
        /// server (include any `Bearer ` prefix yourself).
        public var authorization: String?
        public var headers: [String: String]?

        public init(
            serverUrl: String,
            serverLabel: String,
            serverDescription: String? = nil,
            allowedTools: [String]? = nil,
            authorization: String? = nil,
            headers: [String: String]? = nil
        ) {
            self.serverUrl = serverUrl
            self.serverLabel = serverLabel
            self.serverDescription = serverDescription
            self.allowedTools = allowedTools
            self.authorization = authorization
            self.headers = headers
        }
    }

    /// Render to a `[String: Any]` ready for embedding under `session.tools`.
    /// Throws `xAIRealtimeError.encoding` if `parametersJSON` on a function
    /// tool is not a valid JSON object.
    public func toAny() throws -> [String: Any] {
        switch self {
        case .fileSearch(let ids, let maxResults):
            var d: [String: Any] = ["type": "file_search", "vector_store_ids": ids]
            if let maxResults { d["max_num_results"] = maxResults }
            return d
        case .webSearch:
            return ["type": "web_search"]
        case .xSearch(let handles):
            var d: [String: Any] = ["type": "x_search"]
            if let handles { d["allowed_x_handles"] = handles }
            return d
        case .mcp(let cfg):
            var d: [String: Any] = [
                "type": "mcp",
                "server_url": cfg.serverUrl,
                "server_label": cfg.serverLabel
            ]
            if let v = cfg.serverDescription { d["server_description"] = v }
            if let v = cfg.allowedTools { d["allowed_tools"] = v }
            if let v = cfg.authorization { d["authorization"] = v }
            if let v = cfg.headers { d["headers"] = v }
            return d
        case .function(let name, let description, let parametersJSON):
            guard let data = parametersJSON.data(using: .utf8),
                  let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw xAIRealtimeError.encoding("function `\(name)` parameters must be a valid JSON object — got: \(parametersJSON.prefix(120))")
            }
            var d: [String: Any] = ["type": "function", "name": name, "parameters": params]
            if let description { d["description"] = description }
            return d
        }
    }
}
