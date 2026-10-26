import Foundation

// BreathingSignal.swift — breathing rate and cardiac coherence read from R-R intervals.
//
// Fork addition for the iOS Breathing tab. Pure and deterministic; no CoreBluetooth.
//
// Breathing modulates the heart period (respiratory sinus arrhythmia, RSA): R-R lengthens on the
// exhale and shortens on the inhale, so the dominant frequency of the R-R series in the respiratory
// band is the breathing rate. This is the standard ECG/RR-derived respiration method; a chest strap's
// beat-to-beat R-R is what makes it usable. Accuracy drops when RSA is weak (fast, shallow breathing,
// or high heart rate), so every estimate is optional rather than a guess.
//
// Coherence follows the published HeartMath definition in spirit: the share of the HRV spectrum
// concentrated in one narrow peak in the 0.04–0.26 Hz range. A slow, regular breath near 6 per minute
// produces one tall peak (high coherence); irregular breathing spreads the power (low coherence).

public enum BreathingSignal {

    /// Tachogram resampling rate (Hz). 4 Hz is the usual choice for HRV spectra.
    public static let resampleHz = 4.0
    /// Shortest span of beats worth reading a spectrum from, seconds.
    public static let minSpanSeconds = 30.0
    /// Fewest cleaned beats worth reading a spectrum from.
    public static let minBeats = 20
    /// Respiratory search band, Hz (3 to 30 breaths per minute).
    public static let respBandHz: ClosedRange<Double> = 0.05...0.5
    /// Coherence peak search band and total band, Hz.
    public static let coherencePeakBandHz: ClosedRange<Double> = 0.04...0.26
    public static let coherenceTotalBandHz: ClosedRange<Double> = 0.0033...0.4
    /// Narrowest half-width of the coherence peak window, Hz. The window widens to the Hann main lobe
    /// (2 / span) on short spans, so a perfectly regular breath scores near 100 instead of losing the
    /// lobe's shoulders: on a 64 s window the lobe is ±0.031 Hz, twice this floor.
    public static let coherencePeakHalfWidthHz = 0.015
    /// Frequency grid step, Hz.
    public static let gridStepHz = 0.0025

    /// Power at each grid frequency of the cleaned, resampled, detrended, Hann-windowed tachogram.
    public struct Spectrum: Equatable, Sendable {
        public let freqs: [Double]
        public let power: [Double]
        /// Length of the resampled tachogram, seconds: it sets how wide a pure tone's peak is.
        public let spanSeconds: Double
    }

    /// The spectrum of a run of consecutive R-R intervals (ms), or nil when there are too few beats.
    /// Ectopic and out-of-range beats are removed with `HRVAnalyzer.cleanRR` first.
    public static func spectrum(rrMs: [Double]) -> Spectrum? {
        let rr = HRVAnalyzer.cleanRR(rrMs)
        guard rr.count >= minBeats else { return nil }
        // Beat times: each interval ends at the running sum.
        var t: [Double] = []
        t.reserveCapacity(rr.count)
        var acc = 0.0
        for v in rr { acc += v / 1000.0; t.append(acc) }
        guard let first = t.first, let last = t.last, last - first >= minSpanSeconds else { return nil }

        // Linear resample at `resampleHz`.
        let dt = 1.0 / resampleHz
        let n = Int(((last - first) / dt).rounded(.down)) + 1
        var x = [Double](repeating: 0, count: n)
        var j = 0
        for k in 0..<n {
            let tk = first + Double(k) * dt
            while j < t.count - 2, t[j + 1] < tk { j += 1 }
            let span = t[j + 1] - t[j]
            let w = span > 0 ? (tk - t[j]) / span : 0
            x[k] = rr[j] + (rr[j + 1] - rr[j]) * min(max(w, 0), 1)
        }

        // Remove the linear trend, then apply a Hann window.
        let meanK = Double(n - 1) / 2.0
        let meanX = x.reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0
        for k in 0..<n {
            let dk = Double(k) - meanK
            sxy += dk * (x[k] - meanX); sxx += dk * dk
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        for k in 0..<n {
            let hann = n > 1 ? 0.5 - 0.5 * cos(2.0 * Double.pi * Double(k) / Double(n - 1)) : 1
            x[k] = (x[k] - meanX - slope * (Double(k) - meanK)) * hann
        }

        // Direct DFT on a fine grid; n is a few hundred, so this is cheap.
        var freqs: [Double] = []
        var power: [Double] = []
        var f = coherenceTotalBandHz.lowerBound
        let top = max(respBandHz.upperBound, coherenceTotalBandHz.upperBound)
        while f <= top + 1e-12 {
            var re = 0.0, im = 0.0
            let w = 2.0 * Double.pi * f * dt
            for k in 0..<n {
                re += x[k] * cos(w * Double(k))
                im -= x[k] * sin(w * Double(k))
            }
            freqs.append(f)
            power.append((re * re + im * im) / Double(n))
            f += gridStepHz
        }
        return Spectrum(freqs: freqs, power: power, spanSeconds: Double(n) * dt)
    }

    /// Breathing rate in breaths per minute from the respiratory peak of the R-R spectrum, or nil.
    public static func breathsPerMinute(rrMs: [Double]) -> Double? {
        guard let s = spectrum(rrMs: rrMs), let hz = peakHz(s, in: respBandHz) else { return nil }
        return hz * 60.0
    }

    /// Coherence score, 0–100: the share of 0.0033–0.4 Hz power within the peak window (see
    /// `peakHalfWidthHz`) around the tallest peak in 0.04–0.26 Hz. nil when there are too few beats.
    public static func coherence(rrMs: [Double]) -> Double? {
        guard let s = spectrum(rrMs: rrMs), let hz = peakHz(s, in: coherencePeakBandHz) else { return nil }
        let halfWidth = peakHalfWidthHz(spanSeconds: s.spanSeconds)
        var peak = 0.0, total = 0.0
        for (f, p) in zip(s.freqs, s.power) {
            if coherenceTotalBandHz.contains(f) { total += p }
            if abs(f - hz) <= halfWidth { peak += p }
        }
        guard total > 0 else { return nil }
        return min(100.0, 100.0 * peak / total)
    }

    /// Half-width of the coherence peak window for a tachogram `spanSeconds` long: the Hann main lobe,
    /// never narrower than `coherencePeakHalfWidthHz`.
    public static func peakHalfWidthHz(spanSeconds: Double) -> Double {
        guard spanSeconds > 0 else { return coherencePeakHalfWidthHz }
        return max(coherencePeakHalfWidthHz, 2.0 / spanSeconds)
    }

    /// The grid frequency of the tallest peak inside `band`, refined by a parabola through its two
    /// neighbours. nil when the band holds no power.
    static func peakHz(_ s: Spectrum, in band: ClosedRange<Double>) -> Double? {
        var best: Int? = nil
        for i in s.freqs.indices where band.contains(s.freqs[i]) {
            if best == nil || s.power[i] > s.power[best!] { best = i }
        }
        guard let i = best, s.power[i] > 0 else { return nil }
        guard i > 0, i < s.freqs.count - 1 else { return s.freqs[i] }
        let a = s.power[i - 1], b = s.power[i], c = s.power[i + 1]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
        return s.freqs[i] + min(max(shift, -0.5), 0.5) * gridStepHz
    }
}
