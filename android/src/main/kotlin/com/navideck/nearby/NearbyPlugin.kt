package com.navideck.nearby

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class NearbyPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.navideck.nearby")
        channel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "acquireMulticastLock" -> {
                val success = acquireMulticastLock()
                result.success(success)
            }
            "releaseMulticastLock" -> {
                val success = releaseMulticastLock()
                result.success(success)
            }
            "isMulticastLockHeld" -> {
                result.success(multicastLock?.isHeld == true)
            }
            else -> result.notImplemented()
        }
    }

    private fun acquireMulticastLock(): Boolean {
        return try {
            if (multicastLock == null) {
                val wifiManager = context?.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                multicastLock = wifiManager?.createMulticastLock("nearby_multicast_lock")?.apply {
                    setReferenceCounted(false)
                }
            }
            multicastLock?.let {
                if (!it.isHeld) {
                    it.acquire()
                }
            }
            multicastLock?.isHeld == true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun releaseMulticastLock(): Boolean {
        return try {
            multicastLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        releaseMulticastLock()
        multicastLock = null
        context = null
    }
}
