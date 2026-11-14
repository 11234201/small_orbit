package dev.smallorbit.small_orbit

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var feedbackTone: android.media.ToneGenerator? = null
    private var lastFeedback = 0L
    private var permissionReply: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ReminderScheduler.createChannel(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "small_orbit/platform")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "syncFocus" -> { FocusScheduler.update(this, call.arguments as? Map<*, *>); result.success(null) }
                        "showFocusNotification" -> {
                            FocusScheduler.deliver(this, call.argument<String>("id") ?: ""); result.success(null)
                        }
                        "playFeedback" -> {
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastFeedback > 150) {
                                lastFeedback = now
                                val tone = feedbackTone ?: android.media.ToneGenerator(android.media.AudioManager.STREAM_MUSIC, 18).also { feedbackTone = it }
                                tone.startTone(android.media.ToneGenerator.TONE_PROP_ACK, 65)
                            }
                            result.success(null)
                        }
                        "syncReminders" -> {
                            ReminderScheduler.update(this, call.arguments as String)
                            result.success(null)
                        }
                        "getNotificationStatus" -> {
                            val alarms = getSystemService(AlarmManager::class.java)
                            @Suppress("DEPRECATION")
                            val packageInfo = packageManager.getPackageInfo(packageName, 0)
                            result.success(mapOf("notifications" to getSystemService(NotificationManager::class.java).areNotificationsEnabled(),
                                "version" to packageInfo.versionName,
                                "channel" to ReminderScheduler.channelEnabled(this),
                                "exact" to (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms())))
                        }
                        "requestNotifications" -> {
                            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                if (permissionReply != null) { result.success(null) }
                                else {
                                    permissionReply = result
                                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 302)
                                }
                            } else { result.success(null) }
                        }
                        "openNotificationSettings" -> {
                            val action = if (getSystemService(NotificationManager::class.java).areNotificationsEnabled())
                                Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS else Settings.ACTION_APP_NOTIFICATION_SETTINGS
                            startActivity(Intent(action).putExtra(Settings.EXTRA_APP_PACKAGE,packageName)
                                .putExtra(Settings.EXTRA_CHANNEL_ID, ReminderScheduler.channelId))
                            result.success(null)
                        }
                        "requestExactAlarms" -> {
                            if (Build.VERSION.SDK_INT >= 31) startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) { result.error("PLATFORM", error.message, null) }
            }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 302) {
            permissionReply?.success(null)
            permissionReply = null
            ReminderScheduler.scheduleAll(this)
            try { FocusScheduler.schedule(this) } catch (error: Exception) { android.util.Log.e("SmallOrbit", "Focus scheduling failed", error) }
        }
    }
    override fun onResume() {
        super.onResume(); ReminderScheduler.scheduleAll(this)
        try { FocusScheduler.schedule(this) } catch (error: Exception) { android.util.Log.e("SmallOrbit", "Focus scheduling failed", error) }
    }
    override fun onDestroy() { feedbackTone?.release(); feedbackTone = null; super.onDestroy() }
}
