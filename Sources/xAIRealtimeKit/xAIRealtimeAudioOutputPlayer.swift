//
//  xAIRealtimeAudioOutputPlayer.swift
//  AVAudioPlayerNode wrapper for streaming PCM16 audio deltas from a Voice
//  Agent session straight to the speaker. Output defaults to 24 kHz mono PCM16
//  — matched to the xAI realtime default output format.
//
//  Implements the "wait for playback to drain" hook required by the xAI Voice
//  Agent best practices section on audio overlap during tool calls:
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
    /// Outstanding scheduled buffers that haven't reached the speaker yet.
    private let pending = OSAllocatedUnfairLock<Int>(initialState: 0)

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
    @MainActor
    public func attach(to engine: AVAudioEngine) {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        self.playerNode = player
        self.attachedEngine = engine
    }

    /// Start the player node. Safe to call repeatedly.
    @MainActor
    public func start() {
        guard let player = playerNode, !player.isPlaying else { return }
        player.play()
    }

    /// Decode base64 PCM16 (the shape of `response.output_audio.delta.delta`)
    /// and schedule it for playback.
    @MainActor
    public func play(base64 b64: String) {
        guard let data = Data(base64Encoded: b64) else { return }
        play(pcm16Bytes: data)
    }

    /// Schedule a raw PCM16 buffer (Int16 little-endian, mono, at the
    /// configured `sampleRate`) for playback.
    @MainActor
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
        pending.withLock { $0 += 1 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [pending] _ in
            pending.withLock { $0 = max(0, $0 - 1) }
        }
        if !player.isPlaying { player.play() }
    }

    /// Stop current playback (and discard any queued buffers) without
    /// detaching the player. Useful for barge-in / `speechStarted` handling.
    @MainActor
    public func interrupt() {
        playerNode?.stop()
        pending.withLock { $0 = 0 }
        playerNode?.play()
    }

    /// Returns once every scheduled buffer has been consumed by the output
    /// hardware. Use this between sending a `function_call_output` and the
    /// follow-up `createResponse` to avoid overlapping audio (per the
    /// "Avoid Audio Overlap During Tool Calls" recommendation).
    public func waitForPlaybackToDrain(pollIntervalMillis: Int = 50) async {
        while pending.withLock({ $0 > 0 }) {
            try? await Task.sleep(for: .milliseconds(pollIntervalMillis))
        }
    }

    @MainActor
    public func stop() {
        playerNode?.stop()
        playerNode = nil
        attachedEngine = nil
        pending.withLock { $0 = 0 }
    }
}
