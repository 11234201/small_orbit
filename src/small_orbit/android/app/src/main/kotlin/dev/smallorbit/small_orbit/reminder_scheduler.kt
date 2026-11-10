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
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneId

object ReminderScheduler {
    private const val channelId = "little_things"
    private fun prefs(context: Context) = context.getSharedPreferences("orbit_reminders", Context.MODE_PRIVATE)
    fun createChannel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(channelId, "小事提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "你为小事星球设置的本地待办提醒"
            })
    }
    private fun config(context: Context) = JSONObject(prefs(context).getString("config", "{\"enabled\":false,\"tasks\":[]}")!!)
    private fun alarmIntent(context: Context, id: String, day: String = ""): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            data = Uri.parse("smallorbit://reminder/$id")
            putExtra("id", id); putExtra("day", day)
        }
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun cancel(context: Context, id: String) {
        context.getSystemService(AlarmManager::class.java).cancel(alarmIntent(context, id))
        context.getSystemService(NotificationManager::class.java).cancel(id, 1)
    }
    fun update(context: Context, source: String) {
        val incoming = JSONObject(source)
        incoming.getJSONArray("tasks")
        val old = config(context).getJSONArray("tasks")
        for (i in 0 until old.length()) cancel(context, old.getJSONObject(i).getString("id"))
        check(prefs(context).edit().putString("config", source).commit()) { "无法保存提醒配置" }
        scheduleAll(context, true)
    }
    fun scheduleAll(context: Context, strict: Boolean = false) {
        try {
            createChannel(context)
            val config = config(context)
            val tasks = config.getJSONArray("tasks")
            for (i in 0 until tasks.length()) {
                val task = tasks.getJSONObject(i)
                if (config.optBoolean("enabled")) schedule(context, task) else cancel(context, task.getString("id"))
            }
        } catch (error: Exception) {
            if (strict) throw error
            android.util.Log.e("SmallOrbit", "Schedule failed", error)
        }
    }
    private fun receipt(task: JSONObject, day: LocalDate) = "${task.getString("id")}:$day:${task.getInt("reminderMinute")}"
    private fun isComplete(task: JSONObject, day: LocalDate): Boolean {
        val key = if (task.getString("repeat") == "none") "once" else day.toString()
        return !task.getJSONObject("records").isNull(key)
    }
    private fun schedule(context: Context, task: JSONObject, after: LocalDate? = null) {
        val id = task.getString("id")
        if (task.isNull("date") || task.isNull("reminderMinute")) { cancel(context, id); return }
        val repeat = task.getString("repeat")
        val start = LocalDate.parse(task.getString("date"))
        val today = LocalDate.now()
        val delivered = prefs(context).getStringSet("delivered", emptySet())!!
        val day = ReminderPlan.next(start,repeat,today,after) { candidate ->
            isComplete(task,candidate) || delivered.contains(receipt(task,candidate))
        } ?: run { cancel(context,id); return }
        val minute = task.getInt("reminderMinute")
        val instant = day.atTime(minute / 60, minute % 60).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val trigger = maxOf(instant, System.currentTimeMillis()+1000)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val intent = alarmIntent(context,id,day.toString())
        try {
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,trigger,intent)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,trigger,intent)
        } catch (_: SecurityException) { alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,trigger,intent) }
    }
    fun deliver(context: Context, id: String, dayText: String) {
        val config = config(context)
        if (!config.optBoolean("enabled")) return
        val tasks = config.getJSONArray("tasks")
        val task = (0 until tasks.length()).map { tasks.getJSONObject(it) }.firstOrNull { it.getString("id") == id } ?: return
        val day = LocalDate.parse(dayText)
        val start = LocalDate.parse(task.getString("date"))
        val minute = task.getInt("reminderMinute")
        val due = day.atTime(minute / 60,minute % 60).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        if (!ReminderPlan.contains(start,task.getString("repeat"),day) || due > System.currentTimeMillis()) {
            schedule(context,task); return
        }
        val delivered = prefs(context).getStringSet("delivered", emptySet())!!.toMutableSet()
        val key = receipt(task,day)
        if (!isComplete(task,day) && day == LocalDate.now() && !delivered.contains(key)) {
            val notifications = context.getSystemService(NotificationManager::class.java)
            if (notifications.areNotificationsEnabled()) {
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
                delivered.add(key)
                if (delivered.size > 20000) delivered.remove(delivered.first())
                prefs(context).edit().putStringSet("delivered",delivered).commit()
            }
        }
        if (task.getString("repeat") != "none") schedule(context,task,day)
    }
}
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try { ReminderScheduler.deliver(context,intent.getStringExtra("id") ?: return,intent.getStringExtra("day") ?: return) }
        catch (error: Exception) { android.util.Log.e("SmallOrbit","Reminder failed",error); ReminderScheduler.scheduleAll(context) }
    }
}
class RebootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { ReminderScheduler.scheduleAll(context) }
}
