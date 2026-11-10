package dev.smallorbit.small_orbit

import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test

class ReminderPlanTest {
    private fun day(text: String) = LocalDate.parse(text)
    @Test fun dailySkipsMissedAndCompletedIncludingLeapDay() {
        val next = ReminderPlan.next(day("2024-02-28"),"daily",day("2024-02-29")) { it == day("2024-02-29") }
        assertEquals(day("2024-03-01"),next)
    }
    @Test fun weeklyDoesNotFireOldMissedReminderOnAnotherWeekday() {
        val next = ReminderPlan.next(day("2025-12-29"),"weekly",day("2026-01-03")) { false }
        assertEquals(day("2026-01-05"),next)
    }
    @Test fun receiverSchedulesSuccessorWithoutOpeningApp() {
        val next = ReminderPlan.next(day("2026-11-10"),"daily",day("2026-11-10"),day("2026-11-10")) { false }
        assertEquals(day("2026-11-11"),next)
    }
    @Test fun expiredOneOffDoesNotReappearAndFutureOneStaysFuture() {
        assertNull(ReminderPlan.next(day("2026-11-09"),"none",day("2026-11-10")) { false })
        assertEquals(day("2026-11-20"),ReminderPlan.next(day("2026-11-20"),"none",day("2026-11-10")) { false })
    }
    @Test fun outdatedAlarmIsRejectedAfterDateChange() {
        assertFalse(ReminderPlan.contains(day("2026-11-11"),"none",day("2026-11-10")))
        assertFalse(ReminderPlan.contains(day("2026-11-09"),"weekly",day("2026-11-10")))
        assertTrue(ReminderPlan.contains(day("2026-11-09"),"weekly",day("2026-11-16")))
    }
}
