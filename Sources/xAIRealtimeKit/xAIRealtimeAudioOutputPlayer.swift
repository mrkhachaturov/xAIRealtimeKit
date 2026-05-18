//
//  xAIRealtimeAudioOutputPlayer.swift
//  AVAudioPlayerNode wrapper for streaming PCM16 audio deltas from a Voice
//  Agent session straight to the speaker. Output defaults to 24 kHz mono PCM16
//  — matched to the xAI realtime default output format.
//
//  Implements the "wait for playback to drain" hook required by the xAI Voice
//  Agent best practices on audio overlap during tool calls:
//
//    1. Receive response.function_call_arguments.done
//    2. Send conversation.item.create with function_call_output
//    3. await player.waitForPlaybackToDrain()
//    4. session.createResponse(...)
//

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
import Foundation
import os

public final class xAIRealtimeAudioOutputPlayer: @unchecked Sendable {

    public static let defaultSampleRate: Double = 24_000

    private let sampleRate: Double
    private let outputFormat: AVAudioFormat
    private weak var attachedEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    private struct PlaybackState {
        var pending: Int = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock<PlaybackState>(initialState: .init())

    public init(sampleRate: Double = defaultSampleRate) {
        self.sampleRate = sampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Attach an `AVAudioPlayerNode` to the engine's main mixer at the
    /// configured sample rate. Call before `engine.start()` and before
    /// enabling voice processing on the input node, if any.
    ///
    /// Callable from any isolation domain — matches `AVAudioEngine`'s own
    /// contract. Don't call `attach` / `stop` concurrently.
    public func attach(to engine: AVAudioEngine) {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        self.playerNode = player
        self.attachedEngine = engine
    }

    /// Start the player node. Safe to call repeatedly.
    public func start() {
        guard let player = playerNode, !player.isPlaying else { return }
        player.play()
    }

    /// Decode base64 PCM16 (the shape of `response.output_audio.delta.delta`)
    /// and schedule it for playback.
    ///
    /// Convenience for callers that bypass the typed event decoder (e.g.
    /// consumers of ``xAIRealtimeSession/sendRaw(jsonString:)`` who decode
    /// frames themselves). If you're iterating ``xAIRealtimeSession/events``,
    /// `.audioDelta` already delivers the bytes pre-decoded — use
    /// ``play(pcm16Bytes:)`` instead.
    public func play(base64 b64: String) {
        guard let data = Data(base64Encoded: b64) else { return }
        play(pcm16Bytes: data)
    }

    /// Schedule a raw PCM16 buffer (Int16 little-endian, mono, at the
    /// configured `sampleRate`) for playback.
    public func play(pcm16Bytes: Data) {
        guard let player = playerNode,
              let engine = attachedEngine,
              engine.isRunning
        else { return }
        let frameCount = pcm16Bytes.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: UInt32(frameCount)),
              let floats = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = UInt32(frameCount)
        pcm16Bytes.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<frameCount {
                floats[i] = Float(src[i]) / Float(Int16.max)
            }
        }
        state.withLock { $0.pending += 1 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [state] _ in
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.pending = max(0, s.pending - 1)
                guard s.pending == 0 else { return [] }
                let w = s.waiters
                s.waiters.removeAll()
                return w
            }
            for w in waiters { w.resume() }
        }
        if !player.isPlaying { player.play() }
    }

    /// Stop current playback (and discard any queued buffers) without
    /// detaching the player. Resumes any pending `waitForPlaybackToDrain`
    /// awaiters so they don't hang.
    public func interrupt() {
        playerNode?.stop()
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.pending = 0
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for w in waiters { w.resume() }
        playerNode?.play()
    }

    /// Returns once every scheduled buffer has been consumed by the output
    /// hardware. Backed by the `.dataPlayedBack` completion callback — no
    /// polling. Use this between sending a `function_call_output` and the
    /// follow-up `createResponse` to avoid overlapping audio.
    public func waitForPlaybackToDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeImmediately = state.withLock { s -> Bool in
                guard s.pending > 0 else { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    public func stop() {
        playerNode?.stop()
        playerNode = nil
        attachedEngine = nil
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.pending = 0
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for w in waiters { w.resume() }
    }
}
