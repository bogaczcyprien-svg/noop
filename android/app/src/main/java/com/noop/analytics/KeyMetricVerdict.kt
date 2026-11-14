package com.noop.analytics

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/**
 * FORK: says whether a Key Metric reads good, normal or off against the wearer's usual, instead of a
 * fill bar. Twin of the fork Swift `KeyMetricVerdict`.
 */
object KeyMetricVerdict {
    enum class Rule { HIGHER_IS_BETTER, LOWER_IS_BETTER, STEADY_IS_BETTER, LOW_IS_BAD, NEITHER }
    enum class Tone { GOOD, NORMAL, WATCH, OFF, NEUTRAL }
    enum class Direction { ABOVE, BELOW, INLINE }

    data class Reading(val tone: Tone, val direction: Direction, val strong: Boolean, val usual: Double?)

    const val MIN_HISTORY = 7
    const val NORMAL_Z = 0.5
    const val STRONG_Z = 1.5

    fun usual(history: List<Double>): Double? {
        val values = history.filter { it.isFinite() }
        if (values.size < MIN_HISTORY) return null
        return values.average()
    }

    fun relative(value: Double?, history: List<Double>, rule: Rule, minSpread: Double): Reading? {
        if (value == null || !value.isFinite()) return null
        val mean = usual(history) ?: return null
        val values = history.filter { it.isFinite() }
        val variance = values.sumOf { (it - mean) * (it - mean) } / values.size
        val spread = max(sqrt(variance), minSpread)
        val z = if (spread > 0) (value - mean) / spread else 0.0
        val direction = when {
            z >= NORMAL_Z -> Direction.ABOVE
            z <= -NORMAL_Z -> Direction.BELOW
            else -> Direction.INLINE
        }
        val strong = abs(z) >= STRONG_Z
        val worse = if (strong) Tone.OFF else Tone.WATCH
        val tone = when {
            direction == Direction.INLINE -> Tone.NORMAL
            rule == Rule.NEITHER -> Tone.NEUTRAL
            direction == Direction.ABOVE && rule == Rule.HIGHER_IS_BETTER -> Tone.GOOD
            direction == Direction.BELOW && rule == Rule.LOWER_IS_BETTER -> Tone.GOOD
            direction == Direction.ABOVE && rule == Rule.LOW_IS_BAD -> Tone.NORMAL
            else -> worse
        }
        return Reading(tone, direction, strong, mean)
    }

    fun zone(value: Double?, greenFrom: Double, yellowFrom: Double): Reading? {
        if (value == null || !value.isFinite()) return null
        return when {
            value >= greenFrom -> Reading(Tone.GOOD, Direction.ABOVE, false, null)
            value >= yellowFrom -> Reading(Tone.WATCH, Direction.INLINE, false, null)
            else -> Reading(Tone.OFF, Direction.BELOW, false, null)
        }
    }

    fun recovery(pct: Double?): Reading? = zone(pct, 67.0, 34.0)
    fun rest(pct: Double?): Reading? = zone(pct, 85.0, 70.0)
}
