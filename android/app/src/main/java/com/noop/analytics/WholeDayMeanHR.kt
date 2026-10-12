package com.noop.analytics

/**
 * The arithmetic mean heart rate across a WHOLE calendar/logical day — unlike
 * [PrimarySessionRestingHR] (the longest SLEEP session only), this averages every HR reading in the
 * day's window, so it includes waking hours as well as the night.
 *
 * Takes `List<Double>` rather than `List<Int>` bpm so it can be fed either raw per-sample bpm (an
 * Int reading widens trivially) or already-bucketed mean bpm without the caller doing its own
 * conversion or a second implementation existing for each.
 *
 * Twin of Swift `WholeDayMeanHR`. Keep byte-identical.
 */
object WholeDayMeanHR {

    /** The worn-HR range [PrimarySessionRestingHR]/AnalyticsEngine use when deciding a sample is
     *  real — reused so validity is one rule across every HR-mean computation in this package. */
    val DEFAULT_VALID_BPM = 30.0..220.0

    /** Minimum valid readings before a mean is returned, rather than reporting one off a near-empty
     *  window. Same floor [PrimarySessionRestingHR] uses. */
    const val DEFAULT_MIN_VALID_SAMPLES = 30

    /** Mean of the valid ([validBpm]) readings in [bpm], or null when fewer than [minValidSamples]
     *  clear that range — never a mean computed off too little of the day to mean anything. */
    fun mean(
        bpm: List<Double>,
        validBpm: ClosedFloatingPointRange<Double> = DEFAULT_VALID_BPM,
        minValidSamples: Int = DEFAULT_MIN_VALID_SAMPLES,
    ): Double? {
        val valid = bpm.filter { it in validBpm }
        if (valid.size < minValidSamples) return null
        return valid.sum() / valid.size
    }
}
