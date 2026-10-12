package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The Android twin of the Swift `WholeDayMeanHRTests`; same fixtures, same numbers
 * (cross-platform parity).
 */
class WholeDayMeanHRTest {

    @Test fun meanOfValidSamples() {
        val bpm = List(40) { 70.0 } + List(10) { 50.0 }
        assertEquals(66.0, WholeDayMeanHR.mean(bpm)!!, 1e-9)
    }

    @Test fun invalidSamplesAreExcluded() {
        val bpm = List(40) { 60.0 } + listOf(0.0, 300.0, -5.0, 250.0)
        assertEquals(60.0, WholeDayMeanHR.mean(bpm)!!, 1e-9)
    }

    @Test fun belowMinValidSamplesReturnsNull() {
        assertNull(WholeDayMeanHR.mean(List(5) { 60.0 }))
    }

    @Test fun allInvalidReturnsNull() {
        assertNull(WholeDayMeanHR.mean(List(100) { 0.0 }))
    }

    @Test fun emptyInputReturnsNull() {
        assertNull(WholeDayMeanHR.mean(emptyList()))
    }

    @Test fun constantBpmReturnsExactlyThatValue() {
        assertEquals(58.0, WholeDayMeanHR.mean(List(300) { 58.0 })!!, 1e-9)
    }

    @Test fun acceptsBucketMeansNotJustRawIntegerReadings() {
        val bpm = List(30) { 61.5 } + List(30) { 58.25 }
        assertEquals(59.875, WholeDayMeanHR.mean(bpm)!!, 1e-9)
    }
}
