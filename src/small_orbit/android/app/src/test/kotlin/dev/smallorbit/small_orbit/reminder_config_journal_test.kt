package dev.smallorbit.small_orbit

import org.junit.Assert.*
import org.junit.Test

class ReminderConfigJournalTest {
    private data class Config(val enabled: Boolean, val tasks: Map<String, String>)

    @Test fun successfulPauseIsVisibleToReceiversWhenCancellingOldAlarmsFails() {
        val before = Config(true, mapOf("A" to "due reminder"))
        val paused = before.copy(enabled = false)
        var memory = before
        val journal = ReminderConfigJournal<Config>()
        assertThrows(IllegalStateException::class.java) {
            journal.update(paused, { memory }, { memory = paused; true }, { old, _ ->
                assertEquals(before, old)
                assertFalse(journal.current { memory }.enabled)
                throw IllegalStateException("Alarm service unavailable")
            })
        }
        // A previously queued receiver must not send A after pause was saved.
        assertFalse(journal.current { memory }.enabled)
    }

    @Test fun secondFailedCommitRetainsLastDurableCurrentAndOriginalRetryBaseline() {
        val before = Config(true, mapOf("A" to "original reminder"))
        val paused = before.copy(enabled = false)
        val replacement = Config(true, mapOf("B" to "replacement reminder"))
        var memory = before
        val journal = ReminderConfigJournal<Config>()
        assertThrows(IllegalStateException::class.java) {
            journal.update(paused, { memory }, { memory = paused; true }, { _, _ ->
                throw IllegalStateException("Alarm service unavailable")
            })
        }
        assertThrows(IllegalStateException::class.java) {
            journal.update(replacement, { memory }, { memory = replacement; false }, { _, _ ->
                fail("No platform change before the replacement is durable")
            })
        }
        assertEquals(replacement, memory)
        assertEquals(paused, journal.current { memory })

        var baseline: Config? = null
        journal.update(replacement, { memory }, { memory = replacement; true }, { old, _ ->
            baseline = old
        })
        assertEquals(before, baseline)
        assertEquals(replacement, journal.current { memory })
        journal.update(replacement, { memory }, { true }, { old, _ -> baseline = old })
        assertEquals(replacement, baseline)
    }

    @Test fun failedPauseThenResumeAndUndoDoesNotDismissAValidNotification() {
        val before = Config(true, mapOf("A" to "due reminder"))
        var memory = before
        var writable = false
        val visibleNotifications = mutableSetOf("A")
        val journal = ReminderConfigJournal<Config>()
        fun update(next: Config) = journal.update(
            incoming = next,
            read = { memory },
            persist = { memory = next; writable },
            reconcile = { old, incoming ->
                if (!incoming.enabled) visibleNotifications.clear()
                else visibleNotifications.removeAll(old.tasks.keys.filter { old.tasks[it] != incoming.tasks[it] }.toSet())
            },
        )
        assertThrows(IllegalStateException::class.java) { update(before.copy(enabled = false)) }
        assertFalse(memory.enabled)
        // onResume/boot-time scheduling must use the installed configuration,
        // even though SharedPreferences now exposes the failed pause in memory.
        val resumed = journal.current { memory }
        if (!resumed.enabled) visibleNotifications.clear()
        assertEquals(before, resumed)
        assertEquals(setOf("A"), visibleNotifications)

        writable = true
        update(before) // The user undoes the failed pause before retry succeeds.
        assertEquals(setOf("A"), visibleNotifications)
        assertEquals(before, journal.current { memory })
    }

    @Test fun failedDateChangeIsHiddenFromReceiversUntilRetryReconcilesIt() {
        val before = Config(true, mapOf("A" to "2026-11-10"))
        val moved = Config(true, mapOf("A" to "2026-11-11"))
        var memory = before
        var writable = false
        val journal = ReminderConfigJournal<Config>()
        fun update(next: Config) = journal.update(next, { memory }, {
            memory = next
            writable
        }, { _, _ -> })
        assertThrows(IllegalStateException::class.java) { update(moved) }
        assertEquals("2026-11-10", journal.current { memory }.tasks["A"])
        writable = true
        update(moved)
        assertEquals("2026-11-11", journal.current { memory }.tasks["A"])
    }

    @Test fun failedRemovalRetryStillReconcilesAgainstTheOriginalTask() {
        verifyRetry(undoBeforeRetry = false)
    }

    @Test fun undoingAFailedRemovalPreservesTheOriginalValidNotification() {
        verifyRetry(undoBeforeRetry = true)
    }

    private fun verifyRetry(undoBeforeRetry: Boolean) {
        val original = mapOf("A" to "original reminder")
        var memory = original
        var disk = original
        var writable = false
        val alarmsCancelled = mutableListOf<String>()
        val notificationsDismissed = mutableListOf<String>()
        val journal = ReminderConfigJournal<Map<String, String>>()
        fun update(next: Map<String, String>) = journal.update(
            incoming = next,
            read = { memory },
            persist = {
                memory = next // Failed SharedPreferences commits still do this.
                if (writable) disk = next
                writable
            },
            reconcile = { before, after ->
                alarmsCancelled.addAll(before.keys)
                notificationsDismissed.addAll(before.keys.filter { before[it] != after[it] })
            },
        )
        assertThrows(IllegalStateException::class.java) { update(emptyMap()) }
        assertTrue(memory.isEmpty())
        assertEquals(original, disk)
        assertTrue(alarmsCancelled.isEmpty())
        assertTrue(notificationsDismissed.isEmpty())

        writable = true
        val latest = if (undoBeforeRetry) original else emptyMap()
        update(latest)
        assertEquals(latest, disk)
        assertEquals(listOf("A"), alarmsCancelled)
        assertEquals(if (undoBeforeRetry) emptyList<String>() else listOf("A"), notificationsDismissed)

        // Successful reconciliation resets the baseline for the next update.
        alarmsCancelled.clear()
        notificationsDismissed.clear()
        update(latest)
        assertEquals(latest.keys.toList(), alarmsCancelled)
        assertTrue(notificationsDismissed.isEmpty())
    }
}
