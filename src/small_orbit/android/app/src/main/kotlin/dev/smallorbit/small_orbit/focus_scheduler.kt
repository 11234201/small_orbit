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

object FocusScheduler {
    private var lastDeliveredId: String? = null
    private const val channelId = "orbit_focus"
    private fun prefs(context: Context) = context.getSharedPreferences("orbit_focus", Context.MODE_PRIVATE)
    private fun alarm(context: Context, id: String, deadline: Long) = PendingIntent.getBroadcast(
        context, 7411, Intent(context, FocusReceiver::class.java).apply {
            data = Uri.parse("smallorbit://focus/session")
            putExtra("id", id); putExtra("deadline", deadline)
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    @Synchronized
    fun update(context: Context, values: Map<*, *>?) {
        val id = values?.get("id") as? String ?: ""
        val deadline = (values?.get("deadline") as? Number)?.toLong() ?: 0L
        val phase = values?.get("phase") as? String ?: "ended"
        require(id.length <= 240 && phase in setOf("running", "paused", "finished", "ended"))
        val previousId = prefs(context).getString("id", "")
        check(prefs(context).edit().putString("id", id).putLong("deadline", deadline).putString("phase", phase).commit())
        context.getSystemService(AlarmManager::class.java).cancel(alarm(context, id, deadline))
        if (id != previousId || phase == "paused" || phase == "ended") {
            context.getSystemService(NotificationManager::class.java).cancel("orbit-focus", 2)
        }
        schedule(context)
    }

    @Synchronized
    fun schedule(context: Context) {
        val saved = prefs(context)
        val id = saved.getString("id", "")!!
        val deadline = saved.getLong("deadline", 0)
        when (FocusPlan.nextAction(id, saved.getString("phase", ""), deadline,
            System.currentTimeMillis(), saved.getString("delivered", ""))) {
            FocusAction.NONE -> return
            FocusAction.DELIVER -> { deliver(context, id, deadline); return }
            FocusAction.SCHEDULE -> Unit
        }
        val alarms = context.getSystemService(AlarmManager::class.java)
        val intent = alarm(context, id, deadline)
        try {
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, intent)
            } else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, intent)
        } catch (_: SecurityException) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, intent)
        }
    }

    @Synchronized
    fun deliver(context: Context, id: String, expectedDeadline: Long? = null) {
        val saved = prefs(context)
        val phase = saved.getString("phase", "")
        val deadline = saved.getLong("deadline", 0)
        if (!FocusPlan.canDeliver(id, saved.getString("id", "")!!, phase, deadline, System.currentTimeMillis(),
            if (id == lastDeliveredId) lastDeliveredId else saved.getString("delivered", ""), expectedDeadline)) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(channelId, "专注结束", NotificationManager.IMPORTANCE_DEFAULT))
        if (!manager.areNotificationsEnabled() || manager.getNotificationChannel(channelId).importance == NotificationManager.IMPORTANCE_NONE) return
        val open = PendingIntent.getActivity(context, 7412, Intent(context, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify("orbit-focus", 2, Notification.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("小事星球 · 专注结束")
            .setContentText("这一段专注结束了，回来看看你的进度。")
            .setContentIntent(open).setAutoCancel(true).build())
        lastDeliveredId = id
        check(saved.edit().putString("delivered", id).commit())
    }
}

class FocusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try { FocusScheduler.deliver(context, intent.getStringExtra("id") ?: return, intent.getLongExtra("deadline", 0)) }
        catch (error: Exception) { android.util.Log.e("SmallOrbit", "Focus reminder failed", error) }
    }
}
