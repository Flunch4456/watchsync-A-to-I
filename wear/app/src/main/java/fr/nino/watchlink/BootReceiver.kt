package fr.nino.watchlink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Relance la diffusion après un redémarrage de la montre, si l'option est active. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Redémarrage de la montre, ou app remplacée par une mise à jour : on relance la diffusion
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val prefs = context.getSharedPreferences(HeartRateService.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(HeartRateService.KEY_AUTOSTART, false)) return
        try {
            context.startForegroundService(Intent(context, HeartRateService::class.java))
        } catch (e: Exception) {
            Log.w("WatchLink", "démarrage auto impossible: $e")
        }
    }
}
