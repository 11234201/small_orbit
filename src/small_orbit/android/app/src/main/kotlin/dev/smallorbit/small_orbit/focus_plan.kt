package dev.smallorbit.small_orbit

enum class FocusAction { NONE, DELIVER, SCHEDULE }

object FocusPlan {
    fun nextAction(id: String, phase: String?, deadline: Long, now: Long, deliveredId: String?): FocusAction {
        if ((phase != "running" && phase != "finished") || id.isEmpty() || deadline <= 0 || deliveredId == id) return FocusAction.NONE
        if (deadline <= now) return FocusAction.DELIVER
        return if (phase == "running") FocusAction.SCHEDULE else FocusAction.NONE
    }

    fun canDeliver(id: String, currentId: String, phase: String?, deadline: Long,
                   now: Long, deliveredId: String?, expectedDeadline: Long? = null): Boolean =
        id.isNotEmpty() && id == currentId && id != deliveredId &&
            (phase == "running" || phase == "finished") && deadline > 0 && deadline <= now &&
            (expectedDeadline == null || expectedDeadline == deadline)
}
