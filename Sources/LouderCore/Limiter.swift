import Accelerate
import Foundation

/// A look-ahead brickwall peak limiter with linked channels.
///
/// Every frame's required gain (`ceiling / peak` across all channels, so the stereo image
/// never shifts) is held as a running minimum over the look-ahead window, released
/// exponentially, then box-smoothed over the same window. The audio is delayed by that window,
/// so the gain has already ramped down, linearly and without clicks, by the time a peak comes
/// out. That guarantees no output sample exceeds `ceiling`:
///
/// the output at frame t is x(t − L)·avg(rel(t − L + 1 … t)). Each `rel(t − k)` is at most the
/// minimum of the required gains over frames t − k − L … t − k, a window that contains t − L.
/// So the average is at most the gain frame t − L needed.
///
/// Performance: when the limiter is idle (unity gain for a full window) and a buffer's peak
/// is under the ceiling (the common case), `process` is one vectorised peak scan and a few
/// `memcpy`s that implement the delay. Otherwise it's a single tight scalar pass. The running
/// minimum and the recursive release are inherently serial. All state lives in locals inside
/// the loop. Real-time safe: `process` never allocates, locks or touches reference counts;
/// `prepare` allocates and must not run while `process` might.
public final class Limiter {
    public static let maximumChannels = 8
    /// −1 dBFS, which leaves headroom for inter-sample peaks after the DAC's reconstruction filter.
    public static let defaultCeiling: Float = 0.891

    public let ceiling: Float
    public private(set) var lookahead = 0
    private var releaseCoefficient: Double = 0

    // All sized at `prepare`; force-unwrapped pointers would cost a check per access.
    private var delay = UnsafeMutablePointer<Float>.allocate(capacity: 1)     // lookahead × channels, frame-major ring
    private var spare = UnsafeMutablePointer<Float>.allocate(capacity: 1)     // lookahead × channels, for the fast path
    private var smoothing = UnsafeMutablePointer<Float>.allocate(capacity: 1) // lookahead gains in the box filter
    private var minValues = UnsafeMutablePointer<Float>.allocate(capacity: 1) // monotonic deque for the running minimum
    private var minFrames = UnsafeMutablePointer<Int>.allocate(capacity: 1)

    private var delayChannels = 0
    private var minHead = 0
    private var minCount = 0
    private var position = 0
    private var frame = 0
    private var smoothingSum: Double = 0
    private var release: Double = 1
    /// Consecutive frames the release has sat at exactly unity. Once it reaches `lookahead`,
    /// every gain in the smoothing window is 1 and the fast path is exact.
    private var unityFrames = 0

    public init(ceiling: Float = defaultCeiling, sampleRate: Double = 48_000, lookaheadSeconds: Double = 0.0015, releaseSeconds: Double = 0.1) {
        self.ceiling = ceiling
        prepare(sampleRate: sampleRate, lookaheadSeconds: lookaheadSeconds, releaseSeconds: releaseSeconds)
    }

    deinit { free() }

    /// Sizes the look-ahead for `sampleRate` and clears all state. Allocates.
    public func prepare(sampleRate: Double, lookaheadSeconds: Double = 0.0015, releaseSeconds: Double = 0.1) {
        free()
        lookahead = max(1, Int((sampleRate * lookaheadSeconds).rounded()))
        releaseCoefficient = (exp(-1 / (max(sampleRate, 1) * releaseSeconds)))
        delay = .allocate(capacity: lookahead * Self.maximumChannels)
        spare = .allocate(capacity: lookahead * Self.maximumChannels)
        smoothing = .allocate(capacity: lookahead)
        minValues = .allocate(capacity: lookahead + 1)
        minFrames = .allocate(capacity: lookahead + 1)
        reset()
    }

    /// Silences the delay line and returns to unity gain. Doesn't allocate.
    public func reset() {
        delay.update(repeating: 0, count: lookahead * Self.maximumChannels)
        smoothing.update(repeating: 1, count: lookahead)
        smoothingSum = Double(lookahead)
        minHead = 0
        minCount = 0
        position = 0
        frame = 0
        release = 1
        unityFrames = lookahead
    }

    /// Limits `frames` interleaved frames of `channels` channels in place. Output is delayed
    /// by `lookahead` frames.
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0, channels <= Self.maximumChannels else { return }
        if channels != delayChannels {
            // A new stream layout: the old delay contents don't line up any more.
            delay.update(repeating: 0, count: lookahead * Self.maximumChannels)
            delayChannels = channels
        }

        if unityFrames >= lookahead {
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frames * channels))
            if peak <= ceiling {
                delayOnly(samples, frames: frames, channels: channels)
                return
            }
        }
        limit(samples, frames: frames, channels: channels)
    }

    /// The idle path: unity gain, so the output is just the input delayed by `lookahead`.
    private func delayOnly(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let L = lookahead
        let width = channels * MemoryLayout<Float>.size
        if frames >= L {
            // spare ← last L input frames; shift the input up by L; the ring (oldest first) fills the gap.
            memcpy(spare, samples + (frames - L) * channels, L * width)
            memmove(samples + L * channels, samples, (frames - L) * width)
            memcpy(samples, delay + position * channels, (L - position) * width)
            memcpy(samples + (L - position) * channels, delay, position * width)
            swap(&delay, &spare)
            position = 0
        } else {
            for i in 0..<frames {
                let slot = delay + position * channels
                let sample = samples + i * channels
                for c in 0..<channels {
                    let delayed = slot[c]
                    slot[c] = sample[c]
                    sample[c] = delayed
                }
                position += 1
                if position == L { position = 0 }
            }
        }
        frame += frames
        unityFrames += frames
        // Every required gain in the window was 1; the deque only needs the newest.
        minHead = 0
        minCount = 1
        minValues[0] = 1
        minFrames[0] = frame - 1
    }

    /// The full limiter, one frame at a time.
    private func limit(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        // Copy state into locals: the optimiser keeps them in registers, without exclusivity
        // checks or reloads through `self` on every frame.
        let L = lookahead
        let window = L + 1
        let ceiling = self.ceiling
        let coefficient = releaseCoefficient
        let inverseL = 1 / Double(L)
        let delay = self.delay, smoothing = self.smoothing, minValues = self.minValues, minFrames = self.minFrames
        var minHead = self.minHead, minCount = self.minCount, position = self.position, frame = self.frame
        var sum = smoothingSum, release = self.release, unityFrames = self.unityFrames

        for i in 0..<frames {
            let sample = samples + i * channels
            var peak: Float
            if channels == 2 {
                peak = max(abs(sample[0]), abs(sample[1]))
            } else {
                peak = 0
                for c in 0..<channels { peak = max(peak, abs(sample[c])) }
            }
            let required = peak > ceiling ? ceiling / peak : 1

            // Running minimum over the last `window` frames: expire, then push (so it never
            // holds more than `window` entries), popping anything no smaller than the new value.
            if minCount > 0 && minFrames[minHead] <= frame - window {
                minHead += 1
                if minHead == window { minHead = 0 }
                minCount -= 1
            }
            while minCount > 0 {
                var back = minHead + minCount - 1
                if back >= window { back -= window }
                if minValues[back] < required { break }
                minCount -= 1
            }
            var slot = minHead + minCount
            if slot >= window { slot -= window }
            minValues[slot] = required
            minFrames[slot] = frame
            minCount += 1
            let held = minValues[minHead]

            // Drop instantly, recover exponentially; never above `held`. Kept in Double:
            // in Float each step (gap × (1 − coefficient)) falls under half an ulp while the
            // gap is still ~1e-4, so recovery stalls short of unity and the idle fast path
            // never comes back. Snap once within 1e-6 (−0.00001 dB).
            let target = Double(held)
            release = target < release ? target : target - (target - release) * coefficient
            if target - release < 1e-6 { release = target }
            unityFrames = release == 1 ? unityFrames + 1 : 0

            let smoothed = Float(release)
            sum += Double(smoothed - smoothing[position])
            smoothing[position] = smoothed
            let gain = Float(sum * inverseL)

            let delayed = delay + position * channels
            if channels == 2 {
                let l = delayed[0] * gain, r = delayed[1] * gain
                delayed[0] = sample[0]
                delayed[1] = sample[1]
                // The clamp only guards against rounding in `sum`; the maths stays under it.
                sample[0] = min(max(l, -ceiling), ceiling)
                sample[1] = min(max(r, -ceiling), ceiling)
            } else {
                for c in 0..<channels {
                    let out = delayed[c] * gain
                    delayed[c] = sample[c]
                    sample[c] = min(max(out, -ceiling), ceiling)
                }
            }
            position += 1
            if position == L { position = 0 }
            frame += 1
        }

        // A Double accumulator drifts by ~1e-16 per frame; resync once per buffer anyway.
        var exact: Double = 0
        for j in 0..<L { exact += Double(smoothing[j]) }

        self.minHead = minHead
        self.minCount = minCount
        self.position = position
        self.frame = frame
        self.smoothingSum = exact
        self.release = release
        self.unityFrames = unityFrames
    }

    private func free() {
        delay.deallocate()
        spare.deallocate()
        smoothing.deallocate()
        minValues.deallocate()
        minFrames.deallocate()
    }
}
