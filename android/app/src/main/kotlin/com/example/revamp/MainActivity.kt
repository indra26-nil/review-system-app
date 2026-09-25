package com.example.revamp

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes the device's location to Dart over a [MethodChannel].
 *
 * This uses the framework [LocationManager] rather than Play Services' fused
 * location provider on purpose: it keeps the build free of an extra Gradle
 * dependency, and it lets the app fall back from GPS to the network provider
 * when there is no satellite fix (indoors, for example).
 *
 * Dart calls:
 *   isServiceEnabled    -> Boolean
 *   hasPermission       -> Boolean
 *   requestPermission   -> Boolean (whether it was granted)
 *   getCurrentLocation  -> Map { latitude, longitude, accuracy, ... }
 *
 * Failures use the codes `permission_denied`, `service_disabled`, `timeout` and
 * `busy`, which the Dart side turns into user-facing messages.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.revamp/location"
        const val REQUEST_PERMISSION = 4021

        /** Give up rather than leave the user staring at a spinner. */
        const val FIX_TIMEOUT_MS = 25_000L

        /** A cached fix younger than this is good enough to skip a live request. */
        const val MAX_FIX_AGE_MS = 2 * 60 * 1000L

        val PROVIDERS = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        )
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /** In-flight `getCurrentLocation` call, if any. */
    private var pendingFix: MethodChannel.Result? = null
    private var activeListener: LocationListener? = null
    private var timeoutRunnable: Runnable? = null

    /** In-flight `requestPermission` call, if any. */
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isServiceEnabled" -> result.success(isLocationServiceEnabled())
            "hasPermission" -> result.success(hasLocationPermission())
            "requestPermission" -> requestLocationPermission(result)
            "getCurrentLocation" -> resolveCurrentLocation(result)
            else -> result.notImplemented()
        }
    }

    // ----------------------------------------------------------------- helpers

    private fun locationManager(): LocationManager =
        getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private fun isLocationServiceEnabled(): Boolean = PROVIDERS.any { provider ->
        runCatching { locationManager().isProviderEnabled(provider) }.getOrDefault(false)
    }

    private fun hasLocationPermission(): Boolean {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
        return fine == PackageManager.PERMISSION_GRANTED ||
            coarse == PackageManager.PERMISSION_GRANTED
    }

    private fun Location.toChannelMap(): Map<String, Any?> = mapOf(
        "latitude" to latitude,
        "longitude" to longitude,
        "accuracy" to if (hasAccuracy()) accuracy.toDouble() else null,
        "altitude" to if (hasAltitude()) altitude else null,
        "speed" to if (hasSpeed()) speed.toDouble() else null,
        "bearing" to if (hasBearing()) bearing.toDouble() else null,
        "timestamp" to time,
        "provider" to provider,
    )

    // ------------------------------------------------------------- permissions

    private fun requestLocationPermission(result: MethodChannel.Result) {
        if (hasLocationPermission()) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("busy", "A permission request is already in progress", null)
            return
        }
        permissionResult = result
        requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQUEST_PERMISSION,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_PERMISSION) return
        val result = permissionResult ?: return
        permissionResult = null
        result.success(grantResults.any { it == PackageManager.PERMISSION_GRANTED })
    }

    // ------------------------------------------------------------------ fixing

    private fun resolveCurrentLocation(result: MethodChannel.Result) {
        if (pendingFix != null) {
            result.error("busy", "A location request is already in progress", null)
            return
        }
        if (!hasLocationPermission()) {
            result.error("permission_denied", "Location permission has not been granted", null)
            return
        }
        if (!isLocationServiceEnabled()) {
            result.error("service_disabled", "Location services are turned off", null)
            return
        }

        val manager = locationManager()
        val now = System.currentTimeMillis()

        // A recent cached fix is instant and avoids a slow satellite lock.
        val cached = PROVIDERS
            .mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }
            .maxByOrNull { it.time }
        if (cached != null && now - cached.time <= MAX_FIX_AGE_MS) {
            result.success(cached.toChannelMap())
            return
        }

        val enabled = PROVIDERS.filter {
            runCatching { manager.isProviderEnabled(it) }.getOrDefault(false)
        }
        if (enabled.isEmpty()) {
            result.error("service_disabled", "No location provider is enabled", null)
            return
        }

        pendingFix = result
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) = deliverFix(location)

            // A provider dropping out is not fatal: the others may still fix.
            override fun onProviderEnabled(provider: String) = Unit
            override fun onProviderDisabled(provider: String) = Unit

            @Deprecated("Part of LocationListener below API 30")
            @Suppress("DEPRECATION")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
        }
        activeListener = listener

        for (provider in enabled) {
            runCatching {
                // minTime 0 / minDistance 0f: take the first fix we are given.
                manager.requestLocationUpdates(
                    provider, 0L, 0f, listener, Looper.getMainLooper(),
                )
            }
        }

        timeoutRunnable = Runnable {
            failFix("timeout", "Timed out waiting for a location fix")
        }.also { mainHandler.postDelayed(it, FIX_TIMEOUT_MS) }
    }

    private fun deliverFix(location: Location) {
        val result = pendingFix ?: return
        clearPendingFix()
        result.success(location.toChannelMap())
    }

    private fun failFix(code: String, message: String) {
        val result = pendingFix ?: return
        clearPendingFix()
        result.error(code, message, null)
    }

    private fun clearPendingFix() {
        activeListener?.let { listener ->
            runCatching { locationManager().removeUpdates(listener) }
        }
        activeListener = null
        pendingFix = null
        timeoutRunnable?.let(mainHandler::removeCallbacks)
        timeoutRunnable = null
    }

    override fun onDestroy() {
        clearPendingFix()
        super.onDestroy()
    }
}
