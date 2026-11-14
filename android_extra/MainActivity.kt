package com.meda.cambridge_offline

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cambridge/dl").setMethodCallHandler { call, result ->
            val text = call.argument<String>("text") ?: ""
            when (call.method) {
                "start" -> {
                    askPermissions()
                    try {
                        val i = Intent(this, DownloadService::class.java).putExtra("text", text)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    } catch (e: Exception) {
                    }
                    result.success(null)
                }
                "update" -> {
                    DownloadService.instance?.updateText(text)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, DownloadService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun askPermissions() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        }
        val pm = getSystemService(PowerManager::class.java)
        val sp = getSharedPreferences("dl", MODE_PRIVATE)
        if (!pm.isIgnoringBatteryOptimizations(packageName) && !sp.getBoolean("asked", false)) {
            sp.edit().putBoolean("asked", true).apply()
            try {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
            } catch (e: Exception) {
            }
        }
    }
}
