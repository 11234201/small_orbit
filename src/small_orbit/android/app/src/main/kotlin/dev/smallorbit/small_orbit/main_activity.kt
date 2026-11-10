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
    private var permissionReply: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ReminderScheduler.createChannel(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "small_orbit/platform")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "syncReminders" -> {
                            ReminderScheduler.update(this, call.arguments as String)
                            result.success(null)
                        }
                        "getNotificationStatus" -> {
                            val alarms = getSystemService(AlarmManager::class.java)
                            result.success(mapOf("notifications" to getSystemService(NotificationManager::class.java).areNotificationsEnabled(),
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
                            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,packageName))
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
        }
    }
    override fun onResume() { super.onResume(); ReminderScheduler.scheduleAll(this) }
}
