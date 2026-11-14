package dev.smallorbit.small_orbit

import org.junit.Assert.*
import org.junit.Test

class FocusPlanTest {
    @Test fun finishedSessionRetriesUntilNotificationReceiptExists() {
        // Permission denial does not record delivery. Resume/sync must still try.
        assertEquals(FocusAction.DELIVER, FocusPlan.nextAction("a", "finished", 100, 101, null))
        assertEquals(FocusAction.DELIVER, FocusPlan.nextAction("a", "finished", 100, 120, null))
        assertEquals(FocusAction.NONE, FocusPlan.nextAction("a", "finished", 100, 120, "a"))
    }
    @Test fun onlyRunningFutureSessionsInstallAnAlarm() {
        assertEquals(FocusAction.SCHEDULE, FocusPlan.nextAction("a", "running", 200, 100, null))
        assertEquals(FocusAction.DELIVER, FocusPlan.nextAction("a", "running", 100, 100, null))
        for (phase in listOf("finished", "paused", "ended")) {
            assertEquals(FocusAction.NONE, FocusPlan.nextAction("a", phase, 200, 100, null))
        }
        assertEquals(FocusAction.NONE, FocusPlan.nextAction("a", "paused", 100, 200, null))
        assertEquals(FocusAction.NONE, FocusPlan.nextAction("", "running", 100, 200, null))
    }
    @Test fun onlyCurrentDueSessionCanNotify() {
        assertTrue(FocusPlan.canDeliver("new", "new", "running", 100, 100, null, 100))
        assertFalse(FocusPlan.canDeliver("old", "new", "running", 100, 100, null, 100))
        assertFalse(FocusPlan.canDeliver("new", "new", "running", 100, 99, null, 100))
    }
    @Test fun pauseCancellationAndOldAlarmCannotNotify() {
        for (phase in listOf("paused", "ended")) assertFalse(FocusPlan.canDeliver("a", "a", phase, 100, 101, null))
        assertFalse(FocusPlan.canDeliver("a", "a", "running", 200, 300, null, 100))
    }
    @Test fun foregroundAndBackgroundShareOneReceipt() {
        assertTrue(FocusPlan.canDeliver("a", "a", "finished", 100, 101, null))
        assertFalse(FocusPlan.canDeliver("a", "a", "finished", 100, 101, "a"))
        assertFalse(FocusPlan.canDeliver("", "", "finished", 100, 101, null))
    }
}
