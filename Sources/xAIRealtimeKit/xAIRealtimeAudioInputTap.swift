//
//  xAIRealtimeAudioInputTap.swift
//  AVAudioEngine mic-tap helper for streaming PCM16 audio into a Voice Agent
//  realtime session. Output defaults to 24 kHz mono PCM16 — the format the xAI
//  realtime API expects when `audio.input.format` is left at its defaults.
//
//  Owns no audio session / engine lifecycle — pass an externally-managed
//  `AVAudioEngine` and the helper installs its tap on `inputNode`.
//

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
import Foundation

public final class xAIRealtimeAudioInputTap: @unchecked Sendable {

    public static let defaultSampleRate: Double = 24_000
    public static let defaultBufferSize: AVAudioFrameCount = 4_096

    /// PCM16 chunks (Int16 little-endian, mono, at `targetSampleRate`) emitted
    /// as bytes ready for `xAIRealtimeSession.appendInputAudio(bytes:)`.
    public nonisolated let pcm16Chunks: AsyncStream<Data>

    /// 0…1 rolling RMS values for level metering UI. Only the most recent
    /// value is buffered so a slow consumer doesn't memory-leak the producer.
    public nonisolated let rmsLevels: AsyncStream<Float>

    private let chunkContinuation: AsyncStream<Data>.Continuation
    private let rmsContinuation: AsyncStream<Float>.Continuation

    private let targetSampleRate: Double
    private let bufferSize: AVAudioFrameCount
    private weak var attachedEngine: AVAudioEngine?

    public init(targetSampleRate: Double = defaultSampleRate, bufferSize: AVAudioFrameCount = defaultBufferSize) {
        self.targetSampleRate = targetSampleRate
        self.bufferSize = bufferSize
        let (chunkStream, chunkCont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let (rmsStream, rmsCont) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.pcm16Chunks = chunkStream
        self.chunkContinuation = chunkCont
        self.rmsLevels = rmsStream
        self.rmsContinuation = rmsCont
    }

    deinit {
        chunkContinuation.finish()
        rmsContinuation.finish()
    }

    /// Install a tap on the engine's `inputNode`. The caller owns the engine
    /// (`AVAudioSession` category, `.prepare()`, `.start()`, lifecycle).
    /// Throws if the input format is invalid or the converter can't be built.
    @MainActor
    public func install(on engine: AVAudioEngine) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw xAIRealtimeError.encoding("audio input has zero sample rate (mic not configured?)")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw xAIRealtimeError.encoding("could not create target PCM16 format at \(Int(targetSampleRate)) Hz")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw xAIRealtimeError.encoding("could not create AVAudioConverter (\(inputFormat) → \(targetFormat))")
        }

        let box = ConverterBox(converter: converter, source: inputFormat, target: targetFormat)
        let chunkCont = chunkContinuation
        let rmsCont = rmsContinuation

        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            // Render thread.
            rmsCont.yield(Self.computeRMS(buffer: buffer))
            if let pcm = Self.toPCM16(buffer: buffer, box: box) {
                chunkCont.yield(pcm)
            }
        }
        self.attachedEngine = engine
    }

    /// Remove the tap. The streams stay open (next `install` will reuse them);
    /// call ``finish()`` to terminate them.
    @MainActor
    public func stop() {
        attachedEngine?.inputNode.removeTap(onBus: 0)
        attachedEngine = nil
    }

    /// Stop the tap AND terminate the streams so consumers exit their loops.
    @MainActor
    public func finish() {
        stop()
        chunkContinuation.finish()
        rmsContinuation.finish()
    }

    // MARK: - Internals

    private struct ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        let source: AVAudioFormat
        let target: AVAudioFormat
    }

    /// RMS across a buffer's first channel. Handles float and Int16 sources.
    static func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        if let floats = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<count { sum += floats[i] * floats[i] }
            return sqrt(sum / Float(count))
        }
        if let int16s = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<count {
                let v = Float(int16s[i]) / Float(Int16.max)
                sum += v * v
            }
            return sqrt(sum / Float(count))
        }
        return 0
    }

    private static func toPCM16(buffer: AVAudioPCMBuffer, box: ConverterBox) -> Data? {
        // Output capacity must cover the resampled frame count + headroom.
        let scale = box.target.sampleRate / box.source.sampleRate
        let estimated = AVAudioFrameCount(Double(buffer.frameLength) * scale)
        let capacity = max(estimated, AVAudioFrameCount(box.target.sampleRate))
        guard let out = AVAudioPCMBuffer(pcmFormat: box.target, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let flag = OneShotFlag()
        box.converter.convert(to: out, error: &error) { _, status in
            if flag.consumed { status.pointee = .noDataNow; return nil }
            flag.consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let int16s = out.int16ChannelData?[0] else { return nil }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: int16s, count: byteCount)
    }

    /// Reference-type flag used to silence Sendable warnings on the converter
    /// callback (which captures by reference). The callback runs synchronously
    /// inside `convert(to:error:withInputFrom:)`, so no real race exists.
    private final class OneShotFlag: @unchecked Sendable {
        var consumed = false
    }
}
