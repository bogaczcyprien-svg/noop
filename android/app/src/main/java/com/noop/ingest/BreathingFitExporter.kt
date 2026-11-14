package com.noop.ingest

import java.io.ByteArrayOutputStream

/**
 * FORK: writes a breathing session as a FIT activity (heart rate, breathing rate per second, every R-R)
 * so intervals.icu shows it like a workout. Twin of the fork Swift `BreathingFitExporter`, without the
 * CORE temperature fields.
 */
object BreathingFitExporter {
    data class Sample(val ts: Long, val hr: Int?, val breathsPerMin: Double?)

    private const val FIT_EPOCH = 631_065_600L
    private const val SPORT_TRAINING = 10

    fun build(samples: List<Sample>, rrMs: List<Int>, startTs: Long, endTs: Long): ByteArray {
        val body = ByteArrayOutputStream()

        // file_id: type = activity, manufacturer = development, time_created.
        defn(body, 0, 0, listOf(Triple(0, 1, 0x00), Triple(1, 2, 0x84), Triple(4, 4, 0x86)))
        body.write(0)
        u8(body, 4); u16(body, 255); u32(body, fitTime(startTs))

        // record: timestamp, heart_rate, enhanced_respiration_rate. A second without HR is dropped.
        val written = samples.sortedBy { it.ts }.filter { it.hr != null }
        defn(body, 1, 20, listOf(Triple(253, 4, 0x86), Triple(3, 1, 0x02), Triple(108, 2, 0x84)))
        for (s in written) {
            body.write(1)
            u32(body, fitTime(s.ts))
            u8(body, (s.hr ?: 0).coerceIn(1, 254))
            val b = s.breathsPerMin
            if (b != null && b > 0) u16(body, Math.round(b * 100).toInt().coerceAtMost(65_534)) else u16(body, 0xFFFF)
        }

        // hrv: one R-R per message, in milliseconds.
        defn(body, 2, 78, listOf(Triple(0, 2, 0x84)))
        for (rr in rrMs) if (rr in 1 until 0xFFFF) { body.write(2); u16(body, rr) }

        val hrs = samples.mapNotNull { it.hr }
        val avgHr = if (hrs.isEmpty()) null else Math.round(hrs.average()).toInt()
        val maxHr = hrs.maxOrNull()
        val elapsedMs = (maxOf(0L, endTs - startTs) * 1000L) and 0xFFFFFFFFL

        // lap: one, spanning the session.
        defn(body, 3, 19, listOf(Triple(253, 4, 0x86), Triple(2, 4, 0x86), Triple(7, 4, 0x86), Triple(8, 4, 0x86)))
        body.write(3)
        u32(body, fitTime(endTs)); u32(body, fitTime(startTs)); u32(body, elapsedMs); u32(body, elapsedMs)

        // session
        val sf = mutableListOf(Triple(253, 4, 0x86), Triple(2, 4, 0x86), Triple(7, 4, 0x86), Triple(8, 4, 0x86), Triple(5, 1, 0x00))
        val sd = ByteArrayOutputStream()
        u32(sd, fitTime(endTs)); u32(sd, fitTime(startTs)); u32(sd, elapsedMs); u32(sd, elapsedMs); u8(sd, SPORT_TRAINING)
        if (avgHr != null) { sf += Triple(16, 1, 0x02); u8(sd, avgHr.coerceIn(1, 254)) }
        if (maxHr != null) { sf += Triple(17, 1, 0x02); u8(sd, maxHr.coerceIn(1, 254)) }
        defn(body, 4, 18, sf)
        body.write(4)
        body.write(sd.toByteArray())

        // activity: timestamp, num_sessions = 1, type = manual.
        defn(body, 5, 34, listOf(Triple(253, 4, 0x86), Triple(1, 2, 0x84), Triple(2, 1, 0x00)))
        body.write(5)
        u32(body, fitTime(endTs)); u16(body, 1); u8(body, 0)

        val bodyBytes = body.toByteArray()
        val out = ByteArrayOutputStream()
        u8(out, 12); u8(out, 0x20); u16(out, 2140); u32(out, bodyBytes.size.toLong())
        out.write(".FIT".toByteArray())
        out.write(bodyBytes)
        val crc = RouteExport.fitCrc(out.toByteArray())
        u16(out, crc)
        return out.toByteArray()
    }

    private fun fitTime(unix: Long): Long = (unix - FIT_EPOCH).coerceIn(0, 0xFFFFFFFFL)

    private fun defn(b: ByteArrayOutputStream, local: Int, global: Int, fields: List<Triple<Int, Int, Int>>) {
        u8(b, 0x40 or (local and 0x0F)); u8(b, 0); u8(b, 0); u16(b, global); u8(b, fields.size)
        for ((num, size, type) in fields) { u8(b, num); u8(b, size); u8(b, type) }
    }

    private fun u8(b: ByteArrayOutputStream, v: Int) = b.write(v and 0xFF)
    private fun u16(b: ByteArrayOutputStream, v: Int) { b.write(v and 0xFF); b.write((v shr 8) and 0xFF) }
    private fun u32(b: ByteArrayOutputStream, v: Long) {
        b.write((v and 0xFF).toInt()); b.write(((v shr 8) and 0xFF).toInt())
        b.write(((v shr 16) and 0xFF).toInt()); b.write(((v shr 24) and 0xFF).toInt())
    }
}
