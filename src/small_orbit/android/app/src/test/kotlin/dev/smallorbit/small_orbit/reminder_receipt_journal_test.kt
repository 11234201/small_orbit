package dev.smallorbit.small_orbit

import org.junit.Assert.*
import org.junit.Test

class ReminderReceiptJournalTest {
    @Test fun retentionDoesNotEvictTodaysReceiptWhenPreferencesReturnAnUnorderedSet() {
        val alreadyToday = "A:2026-11-10:540"
        val veryOld = "B:2024-01-01:540"
        val newToday = "C:2026-11-10:600"
        // A StringSet reload may put today's receipt first, regardless of the
        // order in which the notifications were originally displayed.
        var disk = linkedSetOf(alreadyToday, veryOld).toSet()
        val journal = ReminderReceiptJournal({ disk }, { disk = it; true }, 2)
        journal.record(newToday)
        journal.flush()
        assertEquals(setOf(alreadyToday, newToday), disk)
        val restarted = ReminderReceiptJournal({ disk }, { true }, 2)
        assertTrue(restarted.snapshot().contains(alreadyToday))
    }

    @Test fun legacyMalformedReceiptsAreEvictedBeforeKnownCalendarReceipts() {
        val valid = "A:2026-11-10:540"
        val incoming = "B:2026-11-10:600"
        var disk = linkedSetOf(valid, "unrecognized-old-cache-entry").toSet()
        val journal = ReminderReceiptJournal({ disk }, { disk = it; true }, 2)
        journal.record(incoming)
        journal.flush()
        assertEquals(setOf(valid, incoming), disk)
    }

    @Test fun failedCommitRemainsDirtyEvenWhenPreferencesMemoryHasChanged() {
        var memory = setOf("old")
        var disk = memory
        var writable = false
        var writes = 0
        val journal = ReminderReceiptJournal({ memory }, {
            writes++
            memory = it // Android also changes memory when the disk write fails.
            if (writable) disk = it
            writable
        })
        journal.record("new")
        assertThrows(IllegalStateException::class.java) { journal.flush() }
        assertTrue(journal.snapshot().contains("new"))
        assertEquals(setOf("old"), disk)
        writable = true
        journal.flush()
        assertEquals(setOf("old", "new"), disk)
        assertEquals(2, writes)
        journal.flush()
        assertEquals(2, writes)
    }

    @Test fun failedWritesAccumulateReceiptsWithoutReplayingOrDroppingEarlierOnes() {
        var disk = setOf("existing")
        var writable = false
        val journal = ReminderReceiptJournal({ disk }, {
            if (writable) disk = it
            writable
        })
        journal.record("first")
        assertThrows(IllegalStateException::class.java) { journal.flush() }
        journal.record("second")
        assertTrue(journal.snapshot().containsAll(listOf("existing", "first", "second")))
        writable = true
        journal.flush()
        val restarted = ReminderReceiptJournal({ disk }, { true })
        assertEquals(setOf("existing", "first", "second"), restarted.snapshot())
    }

    @Test fun cleanStartupDoesNotRewritePreferencesAndTheJournalRemainsBounded() {
        var disk = setOf("oldest", "recent")
        var writes = 0
        val journal = ReminderReceiptJournal({ disk }, { disk = it; writes++; true }, 2)
        journal.flush()
        assertEquals(0, writes)
        journal.record("new")
        journal.flush()
        assertEquals(setOf("recent", "new"), disk)
        assertEquals(1, writes)
    }
}
