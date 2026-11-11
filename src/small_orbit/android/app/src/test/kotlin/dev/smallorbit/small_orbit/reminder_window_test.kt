package dev.smallorbit.small_orbit

import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test

class ReminderWindowTest {
    private val day = LocalDate.of(2026, 11, 11)
    private fun reminders(count: Int) = (0 until count).map {
        PlannedReminder("task-$it", day, 1000L + it)
    }

    private class Alarms {
        val active = mutableMapOf<String, PlannedReminder>()
        var registry = emptySet<String>()
        var peak = 0
        fun reconcile(candidates: List<PlannedReminder>) {
            ReminderWindow.reconcile(candidates, registry,
                persist = { registry = it.toSet() },
                cancel = { active.remove(it) },
                schedule = {
                    check(active.size < 500) { "Android alarm quota reached" }
                    check(it.id in registry) { "Untracked alarm" }
                    active[it.id] = it
                    peak = maxOf(peak, active.size)
                })
        }
    }

    @Test fun tenThousandTasksRefillUntilEveryReminderHasRun() {
        val pending = reminders(10000).reversed().toMutableList()
        val alarms = Alarms()
        val delivered = mutableSetOf<String>()
        alarms.reconcile(pending)
        while (alarms.active.isNotEmpty()) {
            val batch = alarms.active.values.sortedBy { it.triggerAtMillis }
            assertEquals(pending.minOf { it.triggerAtMillis }, batch.first().triggerAtMillis)
            for (reminder in batch) assertTrue(delivered.add(reminder.id))
            alarms.active.clear() // The OS consumed this batch with the app closed.
            pending.removeAll { it.id in delivered }
            alarms.reconcile(pending)
        }
        assertEquals(10000, delivered.size)
        assertTrue(alarms.peak <= ReminderWindow.capacity)
    }

    @Test fun legacyQuotaIsFreedBeforeAnyReplacementIsInstalled() {
        val candidates = reminders(500)
        val alarms = Alarms()
        alarms.registry = candidates.map { it.id }.toSet()
        alarms.active.putAll(candidates.associateBy { it.id })
        alarms.reconcile(candidates.reversed())
        assertEquals(ReminderWindow.capacity, alarms.active.size)
        assertEquals(candidates.take(ReminderWindow.capacity).map { it.id }.toSet(), alarms.registry)
    }

    @Test fun eachReceiverRefillsOneSlotAndReceiptsPreventRedelivery() {
        val candidates = reminders(130)
        val delivered = mutableSetOf<String>()
        val alarms = Alarms()
        repeat(candidates.size) { index ->
            alarms.reconcile(candidates.filter { it.id !in delivered })
            val next = alarms.active.values.minBy { it.triggerAtMillis }
            assertEquals(candidates[index], next)
            alarms.active.remove(next.id)
            assertTrue(delivered.add(next.id))
            assertTrue(alarms.active.keys.none { it in delivered })
        }
        alarms.reconcile(emptyList())
        assertTrue(alarms.active.isEmpty())
        assertEquals(candidates.size, delivered.size)
    }

    @Test fun rescheduleDeleteDisableAndReloadDoNotKeepStaleAlarms() {
        val alarms = Alarms()
        val initial = reminders(100)
        alarms.reconcile(initial)
        // A task outside the first window moves ahead of every existing alarm.
        val moved = initial.last().copy(triggerAtMillis = 1)
        alarms.reconcile(initial.drop(1).dropLast(1) + moved)
        assertFalse(alarms.active.containsKey(initial.first().id))
        assertEquals(moved, alarms.active[moved.id])
        // A fresh scheduler uses the durable registry, including after restore.
        val reloaded = Alarms().also {
            it.registry = alarms.registry
            it.active.putAll(alarms.active)
        }
        reloaded.reconcile(emptyList())
        assertTrue(reloaded.active.isEmpty())
        assertTrue(reloaded.registry.isEmpty())
    }

    @Test fun failedCancellationRetainsRegistryAndDoesNotGrowTheWindow() {
        val old = reminders(80).map { it.id }.toSet()
        val cancelled = mutableSetOf<String>()
        var persisted = false
        var installed = false
        try {
            ReminderWindow.reconcile(emptyList(), old,
                persist = { persisted = true },
                cancel = { if (it == "task-0") error("cancel failed") else cancelled.add(it) },
                schedule = { installed = true })
            fail("Expected cancellation failure")
        } catch (_: IllegalStateException) { }
        assertEquals(79, cancelled.size)
        assertFalse(persisted)
        assertFalse(installed)
    }

    @Test fun registryWriteFailureCannotInstallUntrackedAlarms() {
        var installed = false
        try {
            ReminderWindow.reconcile(reminders(100), emptySet(),
                persist = { error("disk full") }, cancel = {},
                schedule = { installed = true })
            fail("Expected journal failure")
        } catch (_: IllegalStateException) { }
        assertFalse(installed)
    }

    @Test fun oneInstallFailureDoesNotSkipOthersAndCanBeRetried() {
        val alarms = Alarms()
        val candidates = reminders(100)
        try {
            ReminderWindow.reconcile(candidates, emptySet(),
                persist = { alarms.registry = it }, cancel = {},
                schedule = {
                    if (it.id == "task-0") error("temporary platform failure")
                    alarms.active[it.id] = it
                })
            fail("Expected installation failure")
        } catch (_: IllegalStateException) { }
        assertEquals(ReminderWindow.capacity - 1, alarms.active.size)
        alarms.reconcile(candidates)
        assertEquals(ReminderWindow.capacity, alarms.active.size)
        assertTrue(alarms.active.containsKey("task-0"))
    }

    @Test fun recurringTasksCannotStarveEarlierOneOffTasksOutsideTheWindow() {
        val today = reminders(64)
        val waiting = PlannedReminder("outside", day, 2000)
        val alarms = Alarms()
        alarms.reconcile(today + waiting)
        val consumed = today.first()
        alarms.active.remove(consumed.id)
        val tomorrow = consumed.copy(day = day.plusDays(1), triggerAtMillis = 86401000)
        alarms.reconcile(today.drop(1) + waiting + tomorrow)
        assertTrue(alarms.active.containsKey(waiting.id))
        assertFalse(alarms.active.containsKey(tomorrow.id))
    }
}
