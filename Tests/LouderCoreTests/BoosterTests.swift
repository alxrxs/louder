import CoreAudio
import Foundation
import Testing
@testable import LouderCore

@Suite struct LimiterTests {
    /// Runs interleaved `input` through a fresh limiter and returns the output, with the
    /// look-ahead delay removed by flushing zeros through.
    private func limited(_ input: [Float], channels: Int, sampleRate: Double = 48_000, chunk: Int = 512) -> [Float] {
        let limiter = Limiter(sampleRate: sampleRate)
        var samples = input + [Float](repeating: 0, count: limiter.lookahead * channels)
        samples.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            let frames = buffer.count / channels
            while frame < frames {
                let count = min(chunk, frames - frame)
                limiter.process(buffer.baseAddress! + frame * channels, frames: count, channels: channels)
                frame += count
            }
        }
        return Array(samples.dropFirst(limiter.lookahead * channels))
    }

    @Test func isTransparentBelowTheCeiling() {
        let input = (0..<2000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let output = limited(input, channels: 1)
        #expect(zip(input, output).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func neverExceedsTheCeilingEvenAtFullBoost() {
        var generator = SystemRandomNumberGenerator()
        let input = (0..<48_000).map { i -> Float in
            let tone = Float(sin(Double(i) * 0.031)) * 0.7
            let burst: Float = (i / 3000) % 2 == 0 ? Float.random(in: -1...1, using: &generator) : 0
            return (tone + burst) * 4
        }
        let output = limited(input, channels: 2)
        #expect(output.allSatisfy { abs($0) <= Limiter.defaultCeiling })
    }

    @Test func stopsASingleSampleSpike() {
        var input = [Float](repeating: 0.1, count: 400)
        input[200] = 10
        let output = limited(input, channels: 1)
        #expect(output.allSatisfy { abs($0) <= Limiter.defaultCeiling })
        // The spike still comes through at the ceiling rather than being swallowed.
        #expect(abs(output[200] - Limiter.defaultCeiling) < 1e-4)
    }

    @Test func linksChannelsSoTheImageDoesNotShift() {
        // Left is loud, right is quiet; both must be turned down by the same ratio.
        let frames = 4000
        var input = [Float]()
        for i in 0..<frames {
            let s = Float(sin(Double(i) * 0.02))
            input += [s * 3, s * 0.3]
        }
        let output = limited(input, channels: 2)
        for i in stride(from: 1000, to: frames, by: 97) where abs(input[2 * i + 1]) > 0.05 {
            let leftRatio = output[2 * i] / input[2 * i]
            let rightRatio = output[2 * i + 1] / input[2 * i + 1]
            #expect(abs(leftRatio - rightRatio) < 1e-4)
        }
    }

    @Test func recoversAfterATransient() {
        let sampleRate = 48_000.0
        var input = [Float](repeating: 0.2, count: Int(sampleRate))
        for i in 1000..<1100 { input[i] = 2 }
        let output = limited(input, channels: 1, sampleRate: sampleRate)
        // Ducked right after the transient…
        #expect(output[1200] < 0.15)
        // …and back to unity well within a second.
        #expect(abs(output[Int(sampleRate) - 1] - 0.2) < 1e-3)
    }

    @Test func idleFastPathMatchesTheFullLimiter() {
        // Quiet, then a burst, then quiet long enough to fully recover, then quiet again: the
        // idle fast path takes over at different points depending on the chunk size, including
        // chunks shorter than the look-ahead. Every chunking must produce the same output.
        var input = (0..<500_000).map { Float(sin(Double($0) * 0.021)) * 0.3 }
        for i in 20_000..<21_000 { input[i] *= 8 }
        let reference = limited(input, channels: 2, chunk: 1)
        for chunk in [7, 50, 512, 4096, 500_000] {
            let output = limited(input, channels: 2, chunk: chunk)
            let worst = zip(reference, output).enumerated().max { abs($0.1.0 - $0.1.1) < abs($1.1.0 - $1.1.1) }!; #expect(abs(worst.1.0 - worst.1.1) < 1e-5, "chunk \(chunk) worst at \(worst.0): \(worst.1)")
        }
        // The tail is past the release, so it's bit-exact passthrough.
        let firstDiff = zip(reference.suffix(1000), input.suffix(1000)).enumerated().first { $0.1.0 != $0.1.1 }
        #expect(firstDiff == nil, "\(String(describing: firstDiff))")
    }

    @Test func chunkSizeDoesNotChangeTheResult() {
        let input = (0..<6000).map { Float(sin(Double($0) * 0.013)) * 3 }
        let whole = limited(input, channels: 2, chunk: 6000)
        let pieces = limited(input, channels: 2, chunk: 37)
        #expect(zip(whole, pieces).allSatisfy { abs($0 - $1) < 1e-5 })
    }
}

@Suite struct BoosterTests {
    @Test func rendersStereoIntoStereoWithGainAfterTheLookahead() {
        let booster = Booster()
        let latency = booster.latency
        let head: [Float] = [0.1, -0.2, 0.3, -0.1, 0.05, 0.05, -0.05, 0.1]
        withBuffers(source: head + [Float](repeating: 0, count: latency * 2), sourceChannels: 2, output: [2]) { source, output in
            booster.render(source: source, into: output, from: 2, to: 2)
            let out = samples(output[0])
            #expect(out.prefix(latency * 2).allSatisfy { $0 == 0 })
            #expect(out.dropFirst(latency * 2).map { ($0 * 1000).rounded() / 1000 } == head.map { $0 * 2 })
        }
    }

    @Test func fillsExtraOutputChannelsCyclicallyAcrossBuffers() {
        // Non-interleaved 4-channel output: one buffer per channel.
        let booster = Booster()
        let latency = booster.latency
        withBuffers(source: [0.1, 0.2, 0.3, 0.4] + [Float](repeating: 0, count: latency * 2), sourceChannels: 2, output: [1, 1, 1, 1]) { buffer, output in
            booster.render(source: buffer, into: output, from: 1, to: 1)
            #expect(Array(samples(output[0]).suffix(2)) == [0.1, 0.3])
            #expect(Array(samples(output[1]).suffix(2)) == [0.2, 0.4])
            #expect(Array(samples(output[2]).suffix(2)) == [0.1, 0.3])
            #expect(Array(samples(output[3]).suffix(2)) == [0.2, 0.4])
        }
    }

    @Test func rampsGainAcrossBuffer() {
        let booster = Booster()
        let frames = booster.latency * 4
        withBuffers(source: [Float](repeating: 0.1, count: frames), sourceChannels: 1, output: [1]) { source, output in
            booster.render(source: source, into: output, from: 1, to: 3)
            let out = samples(output[0]).dropFirst(booster.latency)
            #expect(abs(out.first! - 0.1) < 1e-6)
            #expect(Array(out) == out.sorted())
            #expect(out.last! < 0.3)
        }
    }

    @Test func chunkedRenderingMatchesTheLimiter() {
        let frames = 300
        let source = (0..<frames * 2).map { Float(sin(Double($0) * 0.37)) * 0.9 }
        let limiter = Limiter()
        var expected = source.map { $0 * 3 }
        expected.withUnsafeMutableBufferPointer { limiter.process($0.baseAddress!, frames: frames, channels: 2) }
        withBuffers(source: source, sourceChannels: 2, output: [2]) { buffer, output in
            Booster(capacity: 16).render(source: buffer, into: output, from: 3, to: 3)
            #expect(zip(samples(output[0]), expected).allSatisfy { abs($0 - $1) < 1e-5 })
        }
    }

    @Test func silenceWhenThereIsNoSource() {
        withBuffers(source: [], sourceChannels: 2, output: [2]) { _, output in
            Booster().render(source: nil, into: output, from: 2, to: 2)
            #expect(samples(output[0]).allSatisfy { $0 == 0 })
        }
    }
}

@Suite struct LevelTests {
    @Test func decibelsRoundTrip() {
        for gain: Float in [1, 1.5, 2, 3.3, 4] {
            #expect(abs(Level.gain(decibels: Level.decibels(gain)) - gain) < 1e-5)
        }
        #expect(abs(Level.maximumDecibels - 12.04) < 0.01)
    }

    @Test func snapsToFivePercentWithinRange() {
        #expect(Level.snapped(1.234) == 1.25)
        #expect(Level.snapped(0.5) == 1)
        #expect(Level.snapped(9) == 4)
    }

    @Test func stepsMoveAndStopAtTheEnds() {
        var gain: Float = 1
        var seen = [gain]
        while gain < 4 {
            gain = Level.step(gain, by: 1)
            #expect(gain > seen.last!)
            seen.append(gain)
            #expect(seen.count < 30)
        }
        #expect(Level.step(4, by: 1) == 4)
        #expect(Level.step(1, by: -1) == 1)
        #expect(Level.step(2, by: -1) < 2)
    }
}

@Suite struct AppSelectionTests {
    let clients = [
        AudioClient(bundleID: "com.google.Chrome.helper", appBundleID: "com.google.Chrome"),
        AudioClient(bundleID: "com.apple.WebKit.GPU", appBundleID: "com.apple.Safari"),
        AudioClient(bundleID: "com.spotify.client.helper", appBundleID: nil),
        AudioClient(bundleID: "com.apple.Music", appBundleID: "com.apple.Music"),
    ]

    @Test func includesHelpersOfSelectedApps() {
        let ids = AppSelection.tapBundleIDs(selected: ["com.google.Chrome", "com.apple.Safari", "com.spotify.client"], clients: clients)
        #expect(ids == [
            "com.apple.Safari", "com.apple.WebKit.GPU", "com.google.Chrome", "com.google.Chrome.helper",
            "com.spotify.client", "com.spotify.client.helper",
        ])
    }

    @Test func leavesOtherAppsAlone() {
        #expect(AppSelection.tapBundleIDs(selected: ["com.apple.Music"], clients: clients) == ["com.apple.Music"])
        #expect(AppSelection.tapBundleIDs(selected: [], clients: clients).isEmpty)
    }
}

@Suite struct WatchdogTests {
    @Test func healthyWhileCallbacksAdvance() {
        var dog = Watchdog()
        #expect(dog.check(callbacks: 0) == .healthy)
        #expect(dog.check(callbacks: 10) == .healthy)
        #expect(dog.check(callbacks: 20) == .healthy)
    }

    @Test func restartsWhenStalledThenGivesUp() {
        var dog = Watchdog(maximumRestarts: 2)
        _ = dog.check(callbacks: 5)
        #expect(dog.check(callbacks: 5) == .restart)
        dog.engineStarted()
        #expect(dog.check(callbacks: 0) == .healthy)   // first sample after a restart
        #expect(dog.check(callbacks: 0) == .restart)
        dog.engineStarted()
        _ = dog.check(callbacks: 0)
        #expect(dog.check(callbacks: 0) == .giveUp)
    }

    @Test func progressForgivesPastStalls() {
        var dog = Watchdog(maximumRestarts: 1)
        _ = dog.check(callbacks: 5)
        #expect(dog.check(callbacks: 5) == .restart)
        dog.engineStarted()
        _ = dog.check(callbacks: 0)
        #expect(dog.check(callbacks: 100) == .healthy)
        #expect(dog.check(callbacks: 100) == .restart)
    }
}

// MARK: - Helpers

private func samples(_ buffer: AudioBuffer) -> [Float] {
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: count))
}

/// Builds a source buffer and an output list whose buffers have the given channel counts,
/// all sized for the source's frame count (or 2 frames when the source is empty).
/// Output starts filled with garbage so tests see what `render` actually wrote.
private func withBuffers(
    source: [Float],
    sourceChannels: Int,
    output channelCounts: [Int],
    _ body: (AudioBuffer, UnsafeMutableAudioBufferListPointer) -> Void
) {
    let frames = source.isEmpty ? 2 : source.count / sourceChannels
    let sourceData = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, source.count))
    _ = sourceData.initialize(from: source)
    let outputs = channelCounts.map { channels -> UnsafeMutableBufferPointer<Float> in
        let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames * channels)
        p.initialize(repeating: 9)
        return p
    }
    let list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
    defer {
        sourceData.deallocate()
        outputs.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for (i, p) in outputs.enumerated() {
        list[i] = AudioBuffer(mNumberChannels: UInt32(channelCounts[i]), mDataByteSize: UInt32(p.count * 4), mData: UnsafeMutableRawPointer(p.baseAddress))
    }
    let sourceBuffer = AudioBuffer(mNumberChannels: UInt32(sourceChannels), mDataByteSize: UInt32(source.count * 4), mData: UnsafeMutableRawPointer(sourceData.baseAddress))
    body(sourceBuffer, list)
}
