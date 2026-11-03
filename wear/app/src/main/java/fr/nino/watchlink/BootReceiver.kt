package fr.nino.watchlink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Relance la diffusion après un redémarrage de la montre, si l'option est active. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences(HeartRateService.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(HeartRateService.KEY_AUTOSTART, false)) return
        try {
            context.startForegroundService(Intent(context, HeartRateService::class.java))
        } catch (e: Exception) {
            Log.w("WatchLink", "démarrage auto impossible: $e")
        }
    }
}
