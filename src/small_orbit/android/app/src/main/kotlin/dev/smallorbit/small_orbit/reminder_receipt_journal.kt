package dev.smallorbit.small_orbit

/**
 * Main-thread receipt state, independent of Android so failed durable writes can
 * be tested. SharedPreferences can update its in-memory value even when commit
 * returns false; only a successful write clears our dirty flag.
 */
class ReminderReceiptJournal(
    private val read: () -> Set<String>,
    private val write: (Set<String>) -> Boolean,
    private val limit: Int = 20000,
) {
    private var receipts: Set<String>? = null
    private var dirty = false
    private val dayPattern = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")

    fun snapshot(): Set<String> = receipts ?: read().toSet().also { receipts = it }

    fun record(receipt: String) {
        val next = LinkedHashSet(snapshot())
        next.add(receipt)
        // SharedPreferences StringSet does not preserve insertion order across
        // process restarts. Evict the oldest calendar date rather than an
        // arbitrary first entry, which might be an alert delivered today.
        while (next.size > limit) next.remove(next.minByOrNull { receiptDay(it) })
        receipts = next
        dirty = true
    }

    private fun receiptDay(receipt: String): String {
        val minuteSeparator = receipt.lastIndexOf(':')
        if (minuteSeparator < 0) return ""
        val daySeparator = receipt.lastIndexOf(':', minuteSeparator - 1)
        if (daySeparator < 1) return ""
        val day = receipt.substring(daySeparator + 1, minuteSeparator)
        val minute = receipt.substring(minuteSeparator + 1).toIntOrNull()
        return if (dayPattern.matches(day) && minute != null && minute in 0..1439) day else ""
    }

    fun flush() {
        if (!dirty) return
        check(write(snapshot())) { "无法保存提醒记录" }
        dirty = false
    }
}
