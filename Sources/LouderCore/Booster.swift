import Accelerate
import CoreAudio

/// The DSP: scales interleaved Float32 samples by a gain, runs them through a look-ahead
/// peak limiter so a boost past 100% gets louder instead of clipping, and writes the result
/// to every output channel.
///
/// Runs on the real-time audio thread. Scratch memory is allocated up front (and again in
/// `prepare`, which must not overlap with `render`), the gain ramp and channel shuffles are
/// vectorised with Accelerate, and the limiter is one pass over each buffer.
public final class Booster {
    public static let minimumGain: Float = 1
    public static let maximumGain: Float = 4

    private let capacity: Int
    private let scratch: UnsafeMutablePointer<Float>
    public let limiter: Limiter

    /// `capacity` is the largest chunk processed at once; longer buffers are processed in pieces.
    public init(capacity: Int = 4096, sampleRate: Double = 48_000) {
        self.capacity = capacity
        scratch = .allocate(capacity: capacity * Limiter.maximumChannels)
        limiter = Limiter(sampleRate: sampleRate)
    }

    deinit { scratch.deallocate() }

    /// Resets the limiter for a new stream. Allocates; call only while not rendering.
    public func prepare(sampleRate: Double) {
        limiter.prepare(sampleRate: sampleRate)
    }

    /// Frames of delay the limiter's look-ahead adds.
    public var latency: Int { limiter.lookahead }

    /// Writes `source` (interleaved Float32) into every channel of `output`, boosted and limited.
    /// Output channels beyond the source's are filled cyclically (L, R, L, R…). The gain ramps
    /// linearly from `from` to `to` across the buffer so slider moves don't click.
    public func render(
        source: AudioBuffer?,
        into output: UnsafeMutableAudioBufferListPointer,
        from: Float,
        to: Float
    ) {
        let sourceChannels = min(Int(source?.mNumberChannels ?? 0), Limiter.maximumChannels)
        let stride = Int(source?.mNumberChannels ?? 0)
        guard let source, sourceChannels > 0, let sourceData = source.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in output { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let sourceFrames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / stride
        var outputFrames = Int.max
        for buffer in output where buffer.mNumberChannels > 0 {
            outputFrames = min(outputFrames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(buffer.mNumberChannels))
        }
        let frames = min(sourceFrames, outputFrames == .max ? 0 : outputFrames)
        let step = frames > 0 ? (to - from) / Float(frames) : 0
        var one: Float = 1

        var start = 0
        while start < frames {
            let count = min(capacity, frames - start)
            let n = vDSP_Length(count)
            for channel in 0..<sourceChannels {
                var gain = from + step * Float(start)
                var gainStep = step
                vDSP_vrampmul(
                    sourceData + start * stride + channel, vDSP_Stride(stride),
                    &gain, &gainStep,
                    scratch + channel, vDSP_Stride(sourceChannels),
                    n
                )
            }
            limiter.process(scratch, frames: count, channels: sourceChannels)

            var channelBase = 0
            for buffer in output {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for channel in 0..<channels {
                    vDSP_vsmul(
                        scratch + (channelBase + channel) % sourceChannels, vDSP_Stride(sourceChannels),
                        &one,
                        data + start * channels + channel, vDSP_Stride(channels),
                        n
                    )
                }
                channelBase += channels
            }
            start += count
        }

        // Anything past the source's length is silence.
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            if bufferFrames > frames {
                memset(data + frames * channels, 0, (bufferFrames - frames) * channels * MemoryLayout<Float>.size)
            }
        }
    }
}
