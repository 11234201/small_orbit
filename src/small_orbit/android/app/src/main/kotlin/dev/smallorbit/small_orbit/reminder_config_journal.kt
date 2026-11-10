package dev.smallorbit.small_orbit

/** Preserve the alarm/notification baseline until a config update is reconciled. */
class ReminderConfigJournal<T : Any> {
    private var original: T? = null
    private var persisted: T? = null

    // Background scheduling and receivers must not act on preferences memory
    // changed by commit(false). After a successful commit they must follow the
    // new durable configuration even if cancelling old platform alarms fails.
    // Keep that separate from the old baseline needed to retry cancellation.
    fun current(read: () -> T): T = persisted ?: original ?: read()

    fun update(incoming: T, read: () -> T, persist: () -> Boolean, reconcile: (T, T) -> Unit) {
        val before = original ?: read().also { original = it }
        // SharedPreferences changes memory even on a failed commit. Retain the
        // original snapshot, not decisions about an intermediate failed edit:
        // the next incoming update may undo that edit before anything changed.
        check(persist()) { "无法保存提醒配置" }
        persisted = incoming
        reconcile(before,incoming)
        original = null
        persisted = null
    }
}
