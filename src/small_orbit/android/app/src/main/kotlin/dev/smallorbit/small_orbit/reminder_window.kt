package dev.smallorbit.small_orbit

import java.time.LocalDate

data class PlannedReminder(val id: String, val day: LocalDate, val triggerAtMillis: Long)

/** Keep a rolling window of alarms, independent of the number of saved tasks. */
object ReminderWindow {
    const val capacity = 64

    fun reconcile(
        candidates: List<PlannedReminder>,
        registered: Set<String>,
        persist: (Set<String>) -> Unit,
        cancel: (String) -> Unit,
        schedule: (PlannedReminder) -> Unit,
    ) {
        val selected = candidates.sortedWith(
            compareBy<PlannedReminder> { it.triggerAtMillis }.thenBy { it.id },
        ).take(capacity)
        val selectedIds = selected.map { it.id }.toSet()
        var failure: Exception? = null
        fun remember(error: Exception) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        // Retire old alarms before adding any new ones, including migration
        // from releases that registered one alarm for every task. If cleanup
        // fails, retain the old registry so the next attempt can finish it.
        for (id in registered - selectedIds) {
            try { cancel(id) } catch (error: Exception) { remember(error) }
        }
        failure?.let { throw it }
        // Journal intent before touching AlarmManager: a failed/partial install
        // or process death must never leave untracked alarms behind.
        persist(selectedIds)
        for (reminder in selected) {
            try { schedule(reminder) } catch (error: Exception) { remember(error) }
        }
        failure?.let { throw it }
    }
}
