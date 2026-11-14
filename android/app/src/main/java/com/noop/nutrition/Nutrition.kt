package com.noop.nutrition

import android.content.Context
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import kotlin.math.abs
import kotlin.math.sqrt

/** FORK: daily macro targets from weight and today's Effort. Twin of the fork Swift `MacroTargets`. */
object MacroTargets {
    const val PROTEIN_BASELINE_G_PER_KG = 1.6
    const val PROTEIN_EFFORT_RANGE_G_PER_KG = 0.6
    const val CARB_BASELINE_G_PER_KG = 3.0
    const val CARB_EFFORT_RANGE_G_PER_KG = 5.0
    const val FALLBACK_KCAL_PER_KG = 30.0
    const val FAT_FLOOR_FRACTION = 0.20
    const val KCAL_PER_G_PROTEIN = 4.0
    const val KCAL_PER_G_CARB = 4.0
    const val KCAL_PER_G_FAT = 9.0
    const val ROUND_TO_G = 5

    data class Grams(val proteinG: Int, val carbsG: Int, val fatG: Int) {
        val totalKcal: Int get() = Math.round(kcal(proteinG.toDouble(), carbsG.toDouble(), fatG.toDouble())).toInt()
    }

    private fun effortFraction(effort: Double?): Double =
        if (effort == null || !effort.isFinite()) 0.0 else effort.coerceIn(0.0, 100.0) / 100.0

    fun proteinGPerKg(effort: Double?) = PROTEIN_BASELINE_G_PER_KG + effortFraction(effort) * PROTEIN_EFFORT_RANGE_G_PER_KG
    fun carbGPerKg(effort: Double?) = CARB_BASELINE_G_PER_KG + effortFraction(effort) * CARB_EFFORT_RANGE_G_PER_KG

    fun roundToNearest(value: Int, step: Int): Int = if (step <= 0) value else ((value + step / 2) / step) * step

    fun kcal(proteinG: Double, carbsG: Double, fatG: Double): Double =
        proteinG * KCAL_PER_G_PROTEIN + carbsG * KCAL_PER_G_CARB + fatG * KCAL_PER_G_FAT

    fun dailyTargets(weightKg: Double, effort: Double?, dailyEnergyKcal: Double?): Grams {
        if (weightKg <= 0) {
            val total = dailyEnergyKcal ?: 0.0
            val fat = if (total > 0) roundToNearest(Math.round(total * FAT_FLOOR_FRACTION / KCAL_PER_G_FAT).toInt(), ROUND_TO_G) else 0
            return Grams(0, 0, fat)
        }
        val protein = roundToNearest(Math.round(weightKg * proteinGPerKg(effort)).toInt(), ROUND_TO_G)
        val carbs = roundToNearest(Math.round(weightKg * carbGPerKg(effort)).toInt(), ROUND_TO_G)
        val total = dailyEnergyKcal ?: (weightKg * FALLBACK_KCAL_PER_KG)
        val remainder = maxOf(0.0, total - protein * KCAL_PER_G_PROTEIN - carbs * KCAL_PER_G_CARB)
        val fat = roundToNearest(Math.round(maxOf(remainder, total * FAT_FLOOR_FRACTION) / KCAL_PER_G_FAT).toInt(), ROUND_TO_G)
        return Grams(protein, carbs, fat)
    }
}

data class Meal(
    val id: String,
    val loggedAt: Long,
    val name: String?,
    val proteinG: Double,
    val carbsG: Double,
    val fatG: Double,
    val caloriesKcal: Double,
    val note: String? = null,
)

data class MealTemplate(
    val id: String,
    val name: String,
    val proteinG: Double,
    val carbsG: Double,
    val fatG: Double,
    val createdAt: Long,
    val lastUsedTs: Long?,
)

/**
 * FORK: the meal log and its saved templates. Kept as JSON in the app prefs rather than a Room table
 * (the iOS twin is GRDB v48/v49), so adding it needs no schema migration. Calories are fixed at log
 * time (4/4/9), as on iOS.
 */
object NutritionStore {
    private const val KEY_MEALS = "noop.nutrition.meals"
    private const val KEY_TEMPLATES = "noop.nutrition.templates"
    private const val MAX_MEALS = 3000

    fun meals(ctx: Context): List<Meal> = runCatching {
        val arr = JSONArray(NoopPrefs.of(ctx).getString(KEY_MEALS, "[]"))
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Meal(o.getString("id"), o.getLong("loggedAt"), o.optString("name").takeIf { o.has("name") && !o.isNull("name") },
                o.getDouble("proteinG"), o.getDouble("carbsG"), o.getDouble("fatG"), o.getDouble("caloriesKcal"),
                o.optString("note").takeIf { o.has("note") && !o.isNull("note") })
        }
    }.getOrDefault(emptyList())

    private fun saveMeals(ctx: Context, meals: List<Meal>) {
        val arr = JSONArray()
        for (m in meals.sortedBy { it.loggedAt }.takeLast(MAX_MEALS)) {
            arr.put(JSONObject().put("id", m.id).put("loggedAt", m.loggedAt).put("name", m.name ?: JSONObject.NULL)
                .put("proteinG", m.proteinG).put("carbsG", m.carbsG).put("fatG", m.fatG)
                .put("caloriesKcal", m.caloriesKcal).put("note", m.note ?: JSONObject.NULL))
        }
        NoopPrefs.of(ctx).edit().putString(KEY_MEALS, arr.toString()).apply()
    }

    fun logMeal(ctx: Context, name: String?, proteinG: Double, carbsG: Double, fatG: Double, at: Long = System.currentTimeMillis() / 1000) {
        val meal = Meal(UUID.randomUUID().toString(), at, name?.trim()?.takeIf { it.isNotEmpty() },
            proteinG, carbsG, fatG, MacroTargets.kcal(proteinG, carbsG, fatG))
        saveMeals(ctx, meals(ctx) + meal)
    }

    fun updateMeal(ctx: Context, meal: Meal) {
        val fixed = meal.copy(caloriesKcal = MacroTargets.kcal(meal.proteinG, meal.carbsG, meal.fatG))
        saveMeals(ctx, meals(ctx).map { if (it.id == meal.id) fixed else it })
    }

    fun deleteMeal(ctx: Context, id: String) = saveMeals(ctx, meals(ctx).filterNot { it.id == id })

    fun mealsOn(ctx: Context, day: LocalDate, zone: ZoneId = ZoneId.systemDefault()): List<Meal> =
        meals(ctx).filter { Instant.ofEpochSecond(it.loggedAt).atZone(zone).toLocalDate() == day }

    fun templates(ctx: Context): List<MealTemplate> = runCatching {
        val arr = JSONArray(NoopPrefs.of(ctx).getString(KEY_TEMPLATES, "[]"))
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            MealTemplate(o.getString("id"), o.getString("name"), o.getDouble("proteinG"), o.getDouble("carbsG"),
                o.getDouble("fatG"), o.getLong("createdAt"), if (o.isNull("lastUsedTs")) null else o.getLong("lastUsedTs"))
        }
    }.getOrDefault(emptyList()).sortedByDescending { it.lastUsedTs ?: it.createdAt }

    private fun saveTemplates(ctx: Context, list: List<MealTemplate>) {
        val arr = JSONArray()
        for (t in list) {
            arr.put(JSONObject().put("id", t.id).put("name", t.name).put("proteinG", t.proteinG).put("carbsG", t.carbsG)
                .put("fatG", t.fatG).put("createdAt", t.createdAt).put("lastUsedTs", t.lastUsedTs ?: JSONObject.NULL))
        }
        NoopPrefs.of(ctx).edit().putString(KEY_TEMPLATES, arr.toString()).apply()
    }

    /** Saving an existing name updates it instead of duplicating (natural key = name). */
    fun saveTemplate(ctx: Context, name: String, proteinG: Double, carbsG: Double, fatG: Double) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        val now = System.currentTimeMillis() / 1000
        val existing = templates(ctx)
        val match = existing.firstOrNull { it.name.equals(trimmed, ignoreCase = true) }
        val next = if (match != null) existing.map { if (it.id == match.id) it.copy(proteinG = proteinG, carbsG = carbsG, fatG = fatG) else it }
        else existing + MealTemplate(UUID.randomUUID().toString(), trimmed, proteinG, carbsG, fatG, now, null)
        saveTemplates(ctx, next)
    }

    fun logFromTemplate(ctx: Context, t: MealTemplate) {
        logMeal(ctx, t.name, t.proteinG, t.carbsG, t.fatG)
        saveTemplates(ctx, templates(ctx).map { if (it.id == t.id) it.copy(lastUsedTs = System.currentTimeMillis() / 1000) else it })
    }

    fun deleteTemplate(ctx: Context, id: String) = saveTemplates(ctx, templates(ctx).filterNot { it.id == id })

    /** Per-day totals (kcal, protein, carbs, fat) for the days that have at least one meal. */
    fun dailyTotals(ctx: Context, zone: ZoneId = ZoneId.systemDefault()): Map<LocalDate, DoubleArray> =
        meals(ctx).groupBy { Instant.ofEpochSecond(it.loggedAt).atZone(zone).toLocalDate() }
            .mapValues { (_, ms) -> doubleArrayOf(ms.sumOf { it.caloriesKcal }, ms.sumOf { it.proteinG }, ms.sumOf { it.carbsG }, ms.sumOf { it.fatG }) }
}

/** FORK: lag-1 Pearson correlation of a nutrition series with next-day Charge. */
object NutritionRecoveryInsights {
    data class Insight(val key: String, val r: Double, val n: Int)

    fun insights(series: Map<String, Map<LocalDate, Double>>, recovery: Map<LocalDate, Double>, minDays: Int = 7): List<Insight> =
        series.mapNotNull { (key, rows) ->
            val pairs = rows.mapNotNull { (day, v) -> recovery[day.plusDays(1)]?.let { v to it } }
            if (pairs.size < minDays) return@mapNotNull null
            pearson(pairs)?.let { Insight(key, it, pairs.size) }
        }.sortedByDescending { abs(it.r) }

    private fun pearson(p: List<Pair<Double, Double>>): Double? {
        val mx = p.map { it.first }.average()
        val my = p.map { it.second }.average()
        var sxy = 0.0; var sxx = 0.0; var syy = 0.0
        for ((x, y) in p) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        if (sxx <= 0 || syy <= 0) return null
        return sxy / sqrt(sxx * syy)
    }
}
