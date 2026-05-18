//
//  xAIRealtimeSession.swift
//  Full-duplex xAI Voice Agent (realtime) client over WebSocket.
//
//  wss://api.x.ai/v1/realtime?model=grok-voice-latest
//
//  OpenAI-Realtime-compatible event protocol — see xAIRealtimeEvent for the
//  modeled inbound events and xAIRealtimeOutbound for outbound encoders.
//

import Foundation

public actor xAIRealtimeSession {

    public struct Configuration: Sendable {
        public var baseURL: URL                       // wss://api.x.ai/v1/realtime
        public var model: xAIRealtimeModel
        public var auth: xAIRealtimeAuth
        public var timeoutSeconds: TimeInterval
        /// When `true` (default) the session replies to server `ping` events
        /// with a `pong` carrying the same `ping_timestamp` before yielding
        /// `.ping` to the caller. Set `false` if your code wants to drive
        /// keepalive itself. Skipping the pong eventually triggers a
        /// server-side disconnect.
        public var autoPong: Bool

        public init(
            baseURL: URL = URL(string: "wss://api.x.ai/v1/realtime")!,
            model: xAIRealtimeModel = .grokVoiceLatest,
            auth: xAIRealtimeAuth,
            timeoutSeconds: TimeInterval = 60,
            autoPong: Bool = true
        ) {
            self.baseURL = baseURL
            self.model = model
            self.auth = auth
            self.timeoutSeconds = timeoutSeconds
            self.autoPong = autoPong
        }

        /// Build the connection URL with the `model` query parameter.
        /// Exposed for testing.
        public func makeURL() -> URL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "model", value: model.rawValue)]
            return components.url!
        }
    }

    // MARK: - Public stream

    public nonisolated let events: AsyncThrowingStream<xAIRealtimeEvent, Error>

    // MARK: - Internals

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncThrowingStream<xAIRealtimeEvent, Error>.Continuation
    private let autoPong: Bool
    private var receiveTask: Task<Void, Never>?
    private var isClosed = false

    private init(task: URLSessionWebSocketTask, autoPong: Bool) {
        self.task = task
        self.autoPong = autoPong
        var local: AsyncThrowingStream<xAIRealtimeEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<xAIRealtimeEvent, Error> { local = $0 }
        self.continuation = local
    }

    deinit {
        receiveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Opening

    /// Open a new Voice Agent session.
    ///
    /// Auth is passed via `Sec-WebSocket-Protocol` (`xai-client-secret.<bearer-or-ephemeral>`)
    /// because `URLSessionWebSocketTask` strips the `Authorization` header during
    /// the HTTP→WebSocket upgrade on Apple platforms.
    public static func open(
        configuration: Configuration,
        urlSession: URLSession? = nil
    ) async throws -> xAIRealtimeSession {
        let session: URLSession = urlSession ?? {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = configuration.timeoutSeconds
            cfg.timeoutIntervalForResource = configuration.timeoutSeconds
            return URLSession(configuration: cfg)
        }()

        let task = session.webSocketTask(
            with: configuration.makeURL(),
            protocols: [configuration.auth.protocolValue]
        )
        task.resume()

        let s = xAIRealtimeSession(task: task, autoPong: configuration.autoPong)
        await s.startReceiveLoop()
        return s
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !isClosed {
            do {
                let message = try await task.receive()
                handle(message: message)
            } catch is CancellationError {
                continuation.finish(throwing: xAIRealtimeError.canceled)
                return
            } catch {
                if !isClosed {
                    // The xAI server uses WebSocket close code 4401 to signal
                    // "ephemeral token expired" (per the realtime-clients.md
                    // best-practices section). Surface it as a typed error so
                    // callers can drive the mint-and-reconnect loop without
                    // poking at URLError internals.
                    if task.closeCode.rawValue == 4401 {
                        continuation.finish(throwing: xAIRealtimeError.ephemeralExpired)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d):
            guard let s = String(data: d, encoding: .utf8) else {
                continuation.yield(.error(code: nil, message: "non-utf8 binary frame from server"))
                return
            }
            text = s
        @unknown default:
            continuation.yield(.error(code: nil, message: "unknown WebSocket message kind"))
            return
        }
        guard let event = xAIRealtimeEvent.decode(text: text) else {
            continuation.yield(.error(code: nil, message: "unparseable server frame"))
            return
        }
        // Keepalive — reply before yielding so a slow consumer can't starve the
        // server's ping budget. Opt out via Configuration.autoPong.
        if autoPong, case let .ping(timestamp) = event, let ts = timestamp {
            Task { [weak self] in
                try? await self?.sendPong(timestamp: ts)
            }
        }
        continuation.yield(event)
    }

    // MARK: - Outgoing (typed helpers)

    /// Apply a typed session configuration. Sends `session.update`.
    public func updateSession(_ config: xAIRealtimeSessionConfig) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.sessionUpdate(config))
    }

    /// Apply a typed session configuration plus a list of tools.
    public func updateSession(_ config: xAIRealtimeSessionConfig, tools: [xAIRealtimeTool]) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.sessionUpdate(config, tools: tools))
    }

    /// Append base64 PCM (or μ-law/A-law per the session's input format).
    public func appendInputAudio(base64: String) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.inputAudioAppend(base64: base64))
    }

    /// Append raw audio bytes — base64-encoded internally. For hot-path mic
    /// streaming consider building the JSON string yourself with
    /// ``xAIRealtimeOutbound/inputAudioAppend(base64:)`` and calling
    /// ``sendRaw(jsonString:)`` to skip an actor hop.
    public func appendInputAudio(bytes: Data) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.inputAudioAppend(bytes: bytes))
    }

    /// Manually commit the audio buffer (only needed when turn detection is off).
    public func commitInputAudio() async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.inputAudioCommit)
    }

    /// Discard the unsent input audio buffer.
    public func clearInputAudio() async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.inputAudioClear)
    }

    /// Send a user-text conversation item.
    public func sendUserText(_ text: String) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.userText(text))
    }

    /// Request the assistant to generate the next response.
    public func createResponse(options: xAIRealtimeResponseCreateOptions? = nil) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.responseCreate(options: options))
    }

    /// Reply to a tool/function invocation with its output, then call
    /// ``createResponse(options:)`` (after audio playback finishes) to continue.
    public func sendFunctionCallOutput(callId: String, output: String) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.functionCallOutput(callId: callId, output: output))
    }

    /// Reply to a server `ping` event.
    public func sendPong(timestamp: Int64) async throws {
        try await sendRaw(jsonString: xAIRealtimeOutbound.pong(timestamp: timestamp))
    }

    // MARK: - Outgoing (raw)

    /// Send a pre-serialized JSON string. Use this for outbound events not
    /// covered by the typed helpers, or for hot-path audio where you've already
    /// built the JSON.
    public func sendRaw(jsonString: String) async throws {
        try await task.send(.string(jsonString))
    }

    // MARK: - Closing

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}
