package dev.smallorbit.small_orbit

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneId

object ReminderScheduler {
    const val channelId = "little_things"
    private const val alarmRegistryKey = "scheduled_ids_v2"
    private fun prefs(context: Context) = context.getSharedPreferences("orbit_reminders", Context.MODE_PRIVATE)
    private var receiptJournal: ReminderReceiptJournal? = null
    private val configJournal = ReminderConfigJournal<JSONObject>()
    private fun receipts(context: Context): ReminderReceiptJournal {
        receiptJournal?.let { return it }
        val store = prefs(context.applicationContext)
        return ReminderReceiptJournal(
            { store.getStringSet("delivered", emptySet())!!.toSet() },
            { store.edit().putStringSet("delivered", it).commit() },
        ).also { receiptJournal = it }
    }
    fun createChannel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(channelId, "小事提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "你为小事星球设置的本地待办提醒"
            })
    }
    fun channelEnabled(context: Context): Boolean {
        val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(channelId)
        return channel != null && channel.importance != NotificationManager.IMPORTANCE_NONE
    }
    private fun readConfig(context: Context) = JSONObject(prefs(context).getString("config", "{\"enabled\":false,\"tasks\":[]}")!!)
    private fun config(context: Context) = configJournal.current { readConfig(context) }
    private fun reminderIntent(context: Context, id: String, day: String = "") =
        Intent(context, ReminderReceiver::class.java).apply {
            data = Uri.parse("smallorbit://reminder/$id")
            putExtra("id", id); putExtra("day", day)
        }
    private fun alarmIntent(context: Context, id: String, day: String): PendingIntent =
        PendingIntent.getBroadcast(context, 0, reminderIntent(context,id,day), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun cancelAlarm(context: Context, id: String) {
        val pending = PendingIntent.getBroadcast(context, 0, reminderIntent(context,id),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
        context.getSystemService(AlarmManager::class.java).cancel(pending)
        pending.cancel()
    }
    private fun sameTaskData(left: JSONObject, right: JSONObject?): Boolean {
        if (right == null || left.length() != right.length()) return false
        val keys = left.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (!right.has(key)) return false
            val first = left.get(key)
            val second = right.get(key)
            if (first is JSONObject) {
                if (second !is JSONObject || !sameTaskData(first,second)) return false
            } else if (first != second) return false
        }
        return true
    }
    fun update(context: Context, source: String) {
        val incoming = JSONObject(source)
        val tasks = incoming.getJSONArray("tasks")
        val nextById = (0 until tasks.length()).associate {
            val task = tasks.getJSONObject(it)
            task.getString("id") to task
        }
        configJournal.update(
            incoming = incoming,
            // This is a rebuildable native cache. A damaged previous cache must
            // not prevent the validated Flutter task file from replacing it.
            read = {
                try { readConfig(context).also { it.getJSONArray("tasks") } }
                catch (_: Exception) { JSONObject().put("enabled", false).put("tasks", JSONArray()) }
            },
            persist = { prefs(context).edit().putString("config", source).commit() },
            reconcile = { before, _ ->
                val old = before.getJSONArray("tasks")
                for (i in 0 until old.length()) {
                    val task = old.optJSONObject(i) ?: continue
                    val id = task.optString("id")
                    if (id.isEmpty()) continue
                    // Retained tasks are reconciled by the rolling window;
                    // deleted legacy tasks are no longer in the new config.
                    if (nextById[id] == null) cancelAlarm(context,id)
                    // Recompute against the newest incoming task. A failed
                    // removal followed by undo must preserve its notification.
                    // Compare JSON values so key reordering on restore is safe.
                    if (!incoming.optBoolean("enabled") || !sameTaskData(task,nextById[id])) {
                        context.getSystemService(NotificationManager::class.java).cancel(id,1)
                    }
                }
            },
        )
        scheduleAll(context, true)
    }
    fun scheduleAll(context: Context, strict: Boolean = false) {
        var failure: Exception? = null
        try { receipts(context).flush() } catch (error: Exception) { failure = error }
        try {
            createChannel(context)
            val config = config(context)
            val tasks = config.getJSONArray("tasks")
            val today = LocalDate.now()
            val now = System.currentTimeMillis()
            val canNotify = context.getSystemService(NotificationManager::class.java).areNotificationsEnabled() && channelEnabled(context)
            val delivered = receipts(context).snapshot()
            val candidates = mutableListOf<PlannedReminder>()
            val taskIds = mutableSetOf<String>()
            for (i in 0 until tasks.length()) {
                val task = tasks.getJSONObject(i)
                val id = task.getString("id")
                taskIds.add(id)
                if (config.optBoolean("enabled")) {
                    plan(task, today, now, canNotify, delivered)?.let { candidates.add(it) }
                } else {
                    context.getSystemService(NotificationManager::class.java).cancel(id, 1)
                }
            }
            val store = prefs(context)
            // No registry means an older release may have registered every
            // task. Cancel the surplus before installing the bounded window.
            val registered = store.getStringSet(alarmRegistryKey, null)?.toSet() ?: taskIds
            ReminderWindow.reconcile(
                candidates, registered,
                persist = { ids ->
                    // Always commit, including after commit(false), which can
                    // have already changed SharedPreferences' in-memory value.
                    check(store.edit().putStringSet(alarmRegistryKey, ids).commit()) { "无法保存提醒调度记录" }
                },
                cancel = { cancelAlarm(context, it) },
                schedule = { schedule(context, it) },
            )
        } catch (error: Exception) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        // Receipt failures must surface to Flutter's retry UI, but must not
        // prevent scheduling the next occurrence after an alarm was consumed.
        failure?.let {
            if (strict) throw it
            android.util.Log.e("SmallOrbit", "Schedule failed", it)
        }
    }
    private fun receipt(task: JSONObject, day: LocalDate) = "${task.getString("id")}:$day:${task.getInt("reminderMinute")}"
    private fun isComplete(task: JSONObject, day: LocalDate): Boolean {
        val key = if (task.getString("repeat") == "none") "once" else day.toString()
        return !task.getJSONObject("records").isNull(key)
    }
    private fun plan(task: JSONObject, today: LocalDate, now: Long, canNotify: Boolean, delivered: Set<String>): PlannedReminder? {
        val id = task.getString("id")
        if (task.isNull("date") || task.isNull("reminderMinute")) return null
        val repeat = task.getString("repeat")
        val start = LocalDate.parse(task.getString("date"))
        val minute = task.getInt("reminderMinute")
        fun instant(day: LocalDate) = day.atTime(minute / 60, minute % 60).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val day = ReminderPlan.next(start,repeat,today) { candidate ->
            isComplete(task,candidate) || delivered.contains(receipt(task,candidate)) ||
                // Denied notifications must not occupy the whole window with
                // already-due alarms. Granting permission/resuming recomputes
                // today's reminders, without falsely marking them delivered.
                (!canNotify && instant(candidate) <= now)
        } ?: return null
        return PlannedReminder(id, day, instant(day))
    }
    private fun schedule(context: Context, reminder: PlannedReminder) {
        val trigger = maxOf(reminder.triggerAtMillis, System.currentTimeMillis()+1000)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val intent = alarmIntent(context,reminder.id,reminder.day.toString())
        try {
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,trigger,intent)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,trigger,intent)
        } catch (_: SecurityException) { alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,trigger,intent) }
    }
    fun deliver(context: Context, id: String, dayText: String) {
        val journal = receipts(context)
        try {
            deliverOccurrence(context,id,dayText,journal)
        } finally {
            // Refill from ALL tasks after every delivery, even with Flutter
            // closed. scheduleAll also retries dirty receipts, and still
            // installs the next window if receipt persistence fails.
            scheduleAll(context, true)
        }
    }
    private fun deliverOccurrence(context: Context, id: String, dayText: String, journal: ReminderReceiptJournal) {
        val config = config(context)
        if (!config.optBoolean("enabled")) return
        val tasks = config.getJSONArray("tasks")
        val task = (0 until tasks.length()).map { tasks.getJSONObject(it) }.firstOrNull { it.getString("id") == id } ?: return
        val day = LocalDate.parse(dayText)
        val start = LocalDate.parse(task.getString("date"))
        val minute = task.getInt("reminderMinute")
        val due = day.atTime(minute / 60,minute % 60).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        if (!ReminderPlan.contains(start,task.getString("repeat"),day) || due > System.currentTimeMillis()) {
            return
        }
        val delivered = journal.snapshot()
        val key = receipt(task,day)
        if (!isComplete(task,day) && day == LocalDate.now() && !delivered.contains(key)) {
            val notifications = context.getSystemService(NotificationManager::class.java)
            if (notifications.areNotificationsEnabled() && channelEnabled(context)) {
                val open = PendingIntent.getActivity(context,0,Intent(context,MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                },PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val notification = Notification.Builder(context,channelId)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle("小事星球 · 该做这件小事啦")
                    .setContentText(task.getString("title"))
                    .setStyle(Notification.BigTextStyle().bigText(task.getString("title")))
                    .setAutoCancel(true).setContentIntent(open).build()
                notifications.notify(id,1,notification)
                journal.record(key)
            }
        }
    }
}
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try { ReminderScheduler.deliver(context,intent.getStringExtra("id") ?: return,intent.getStringExtra("day") ?: return) }
        catch (error: Exception) { android.util.Log.e("SmallOrbit","Reminder failed",error); ReminderScheduler.scheduleAll(context) }
    }
}
class RebootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ReminderScheduler.scheduleAll(context)
        try { FocusScheduler.schedule(context) } catch (error: Exception) { android.util.Log.e("SmallOrbit", "Focus reschedule failed", error) }
    }
}
