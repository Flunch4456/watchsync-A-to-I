package fr.nino.watchlink

import android.content.Context
import java.io.File

/**
 * Journal sur la montre : garde les mesures même sans iPhone pour les envoyer à la reconnexion.
 * Une ligne par mesure : `h,<secondes>,<bpm>` (rythme), `b,<secondes>,<pourcent>` (batterie)
 * ou `s,<jour depuis 1970>,<pas>` (pas du jour).
 */
class SampleLog(context: Context) {
    private val file = File(context.filesDir, "log.csv")
    private val lock = Any()

    class Snapshot(
        val heartRate: List<Pair<Long, Int>>,
        val battery: List<Pair<Long, Int>>,
        val steps: List<Pair<Long, Int>>
    )

    fun appendHeartRate(seconds: Long, bpm: Int) = append("h,$seconds,$bpm")

    fun appendBattery(seconds: Long, percent: Int) = append("b,$seconds,$percent")

    fun appendSteps(epochDay: Long, steps: Int) = append("s,$epochDay,$steps")

    private fun append(line: String) {
        synchronized(lock) {
            try {
                file.appendText(line + "\n")
            } catch (e: Exception) {
                // Le journal est un confort : on ne bloque rien s'il échoue
            }
        }
    }

    /** Tout ce qui est plus récent que `since` (secondes), pour les pas toutes les valeurs. */
    fun readSince(since: Long): Snapshot {
        val heartRate = ArrayList<Pair<Long, Int>>()
        val battery = ArrayList<Pair<Long, Int>>()
        val steps = ArrayList<Pair<Long, Int>>()
        synchronized(lock) {
            if (file.exists()) {
                try {
                    file.forEachLine { line ->
                        val p = line.split(',')
                        if (p.size == 3) {
                            val a = p[1].toLongOrNull()
                            val b = p[2].toIntOrNull()
                            if (a != null && b != null) {
                                when (p[0]) {
                                    "h" -> if (a > since) heartRate.add(a to b)
                                    "b" -> if (a > since) battery.add(a to b)
                                    "s" -> steps.add(a to b)
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    // fichier illisible : on envoie ce qu'on a pu lire
                }
            }
        }
        return Snapshot(heartRate, battery, steps)
    }

    /** Supprime les lignes de plus de 7 jours. */
    fun prune(nowSeconds: Long) {
        val cutoff = nowSeconds - 7L * 24 * 3600
        val cutoffDay = cutoff / 86400
        synchronized(lock) {
            if (!file.exists()) return
            try {
                val kept = file.readLines().filter { line ->
                    val p = line.split(',')
                    val a = if (p.size == 3) p[1].toLongOrNull() else null
                    a != null && (if (p[0] == "s") a >= cutoffDay else a >= cutoff)
                }
                file.writeText(if (kept.isEmpty()) "" else kept.joinToString("\n") + "\n")
            } catch (e: Exception) {
                // on garde le fichier tel quel
            }
        }
    }
}
