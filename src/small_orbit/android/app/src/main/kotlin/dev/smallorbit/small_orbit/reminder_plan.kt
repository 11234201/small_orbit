package dev.smallorbit.small_orbit

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/** Calendar-only recurrence, separated from Android permissions and alarm delivery. */
object ReminderPlan {
    fun next(start: LocalDate, repeat: String, today: LocalDate, after: LocalDate? = null,
             unavailable: (LocalDate) -> Boolean): LocalDate? {
        val interval = if (repeat == "weekly") 7L else 1L
        var day = start
        if (repeat != "none" && today.isAfter(start)) {
            day = start.plusDays(ChronoUnit.DAYS.between(start,today) / interval * interval)
        }
        if (after != null && !day.isAfter(after)) {
            if (repeat == "none") return null
            day = after.plusDays(interval)
        }
        kotlin.repeat(80002) {
            if (!day.isBefore(today) && !unavailable(day)) return day
            if (repeat == "none") return null
            day = day.plusDays(interval)
        }
        return null
    }
    fun contains(start: LocalDate, repeat: String, day: LocalDate): Boolean {
        if (day.isBefore(start)) return false
        return when (repeat) {
            "none" -> day == start
            "weekly" -> ChronoUnit.DAYS.between(start,day) % 7 == 0L
            else -> true
        }
    }
}
