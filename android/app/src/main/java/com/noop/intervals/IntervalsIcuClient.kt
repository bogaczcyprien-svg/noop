package com.noop.intervals

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** FORK: one intervals.icu activity, the fields NOOP reads. Twin of the fork iOS `IntervalsICUActivity`. */
data class IntervalsIcuActivity(
    val id: String,
    val name: String?,
    val type: String?,
    val startDateLocal: String?,
    val movingTime: Int?,
    val elapsedTime: Int?,
    val distance: Double?,
    val calories: Double?,
    val averageHeartrate: Double?,
    val maxHeartrate: Double?,
)

/** FORK: one intervals.icu calendar event (planned workout, note…). Twin of `IntervalsICUEvent`. */
data class IntervalsIcuEvent(
    val id: Long,
    val startDateLocal: String?,
    val type: String?,
    val category: String?,
    val name: String?,
    val description: String?,
    val movingTime: Int?,
    val distance: Double?,
)

/** FORK: one activity stream (`time`, `heartrate`, …), nulls kept where intervals.icu has gaps. */
data class IntervalsIcuStream(val type: String, val data: List<Double?>)

class IntervalsIcuHttpException(val code: Int) : Exception("HTTP $code")

/**
 * FORK: the intervals.icu REST client. Twin of the fork iOS `IntervalsICUClient`: same endpoints, same
 * Basic `API_KEY:<key>` authentication. Every call runs on [Dispatchers.IO].
 */
class IntervalsIcuClient(athleteId: String, private val apiKey: String) {
    private val athleteId = athleteId.ifBlank { "0" }

    private val auth: String
        get() = "Basic " + Base64.encodeToString("API_KEY:$apiKey".toByteArray(), Base64.NO_WRAP)

    private fun base(path: String) = "https://intervals.icu/api/v1/$path".toHttpUrl().newBuilder()

    private suspend fun get(url: okhttp3.HttpUrl): String = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url).header("Authorization", auth).header("Accept", "application/json").build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw IntervalsIcuHttpException(resp.code)
            resp.body?.string() ?: ""
        }
    }

    suspend fun activities(oldest: String, newest: String): List<IntervalsIcuActivity> {
        val url = base("athlete/$athleteId/activities")
            .addQueryParameter("oldest", oldest).addQueryParameter("newest", newest).build()
        val arr = JSONArray(get(url))
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val id = o.optStringOrNull("id") ?: return@mapNotNull null
            IntervalsIcuActivity(
                id = id,
                name = o.optStringOrNull("name"),
                type = o.optStringOrNull("type"),
                startDateLocal = o.optStringOrNull("start_date_local"),
                movingTime = o.optIntOrNull("moving_time"),
                elapsedTime = o.optIntOrNull("elapsed_time"),
                distance = o.optDoubleOrNull("distance"),
                calories = o.optDoubleOrNull("calories"),
                averageHeartrate = o.optDoubleOrNull("average_heartrate"),
                maxHeartrate = o.optDoubleOrNull("max_heartrate"),
            )
        }
    }

    suspend fun events(oldest: String, newest: String, category: String? = null): List<IntervalsIcuEvent> {
        val b = base("athlete/$athleteId/events").addQueryParameter("oldest", oldest).addQueryParameter("newest", newest)
        if (category != null) b.addQueryParameter("category", category)
        val arr = JSONArray(get(b.build()))
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            IntervalsIcuEvent(
                id = o.optLong("id"),
                startDateLocal = o.optStringOrNull("start_date_local"),
                type = o.optStringOrNull("type"),
                category = o.optStringOrNull("category"),
                name = o.optStringOrNull("name"),
                description = o.optStringOrNull("description"),
                movingTime = o.optIntOrNull("moving_time"),
                distance = o.optDoubleOrNull("distance"),
            )
        }
    }

    suspend fun streams(activityId: String, types: List<String>): List<IntervalsIcuStream> {
        val url = base("activity/$activityId/streams.json").addQueryParameter("types", types.joinToString(",")).build()
        val arr = JSONArray(get(url))
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val type = o.optStringOrNull("type") ?: return@mapNotNull null
            val data = o.optJSONArray("data") ?: JSONArray()
            IntervalsIcuStream(type, (0 until data.length()).map { j ->
                if (data.isNull(j)) null else data.optDouble(j).takeIf { !it.isNaN() }
            })
        }
    }

    suspend fun putWellness(
        date: String,
        hrv: Double?,
        restingHR: Int?,
        readiness: Double? = null,
        sleepSecs: Int?,
        sleepScore: Int?,
        weightKg: Double? = null,
        steps: Int? = null,
    ) = withContext(Dispatchers.IO) {
        val body = JSONObject()
        hrv?.let { body.put("hrv", it) }
        restingHR?.let { body.put("restingHR", it) }
        sleepSecs?.let { body.put("sleepSecs", it) }
        sleepScore?.let { body.put("sleepScore", it) }
        weightKg?.let { body.put("weight", it) }
        steps?.let { body.put("steps", it) }
        readiness?.let { body.put("readiness", it) }
        val req = Request.Builder()
            .url(base("athlete/$athleteId/wellness/$date").build())
            .header("Authorization", auth)
            .put(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw IntervalsIcuHttpException(resp.code)
        }
    }

    /** Uploads a FIT file as a new activity; returns the created activity id when intervals.icu reports one. */
    suspend fun uploadActivity(fit: ByteArray, filename: String, name: String, description: String): String? =
        withContext(Dispatchers.IO) {
            val body = MultipartBody.Builder().setType(MultipartBody.FORM)
                .addFormDataPart("file", filename, fit.toRequestBody("application/octet-stream".toMediaType()))
                .build()
            val url = base("athlete/$athleteId/activities")
                .addQueryParameter("name", name).addQueryParameter("description", description).build()
            val req = Request.Builder().url(url).header("Authorization", auth)
                .header("Accept", "application/json").post(body).build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw IntervalsIcuHttpException(resp.code)
                val text = resp.body?.string().orEmpty()
                runCatching {
                    val trimmed = text.trim()
                    if (trimmed.startsWith("[")) JSONArray(trimmed).optJSONObject(0)?.optStringOrNull("id")
                    else JSONObject(trimmed).optStringOrNull("id")
                }.getOrNull()
            }
        }

    /** Reads today's activities as a connection check: success carries the count, failure a short reason. */
    suspend fun testConnection(): Result<Int> = runCatching {
        val today = IntervalsIcuDates.today()
        activities(today, today).size
    }

    companion object {
        internal val http: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()
        }
    }
}

internal fun JSONObject.optStringOrNull(name: String): String? =
    if (!has(name) || isNull(name)) null else opt(name)?.toString()

internal fun JSONObject.optIntOrNull(name: String): Int? =
    if (!has(name) || isNull(name)) null else optDouble(name).takeIf { !it.isNaN() }?.toInt()

internal fun JSONObject.optDoubleOrNull(name: String): Double? =
    if (!has(name) || isNull(name)) null else optDouble(name).takeIf { !it.isNaN() }
