import Foundation

/// Maps the boost between linear gain (what the DSP uses and the readout shows, as a
/// percentage) and decibels (what the slider and hotkeys move in, because loudness is
/// perceived logarithmically: 100→200% sounds like as big a jump as 200→400%).
public enum Level {
    public static let maximumDecibels = decibels(Booster.maximumGain)
    /// One hotkey press.
    public static let stepDecibels: Float = 1.5
    /// The readout settles on multiples of this.
    public static let snap: Float = 0.05

    public static func decibels(_ gain: Float) -> Float {
        20 * log10(max(gain, 1e-6))
    }

    public static func gain(decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    /// Rounds to the nearest 5% and clamps to the boost range.
    public static func snapped(_ gain: Float) -> Float {
        let rounded = (gain / snap).rounded() * snap
        return min(max(rounded, Booster.minimumGain), Booster.maximumGain)
    }

    /// Moves `steps` hotkey steps up (positive) or down, always changing by at least one snap
    /// unit unless already at the end of the range.
    public static func step(_ gain: Float, by steps: Int) -> Float {
        let target = snapped(Self.gain(decibels: decibels(gain) + Float(steps) * stepDecibels))
        if target == snapped(gain) && steps != 0 {
            return snapped(gain + (steps > 0 ? snap : -snap))
        }
        return target
    }
}
