package fr.nino.watchlink

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.os.Build
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Permet à l'app iPhone de voir l'écran de la montre et de la manipuler :
 * captures d'écran réduites en JPEG, touches, glissements et boutons système.
 * Le service ne fait rien tant que l'iPhone lié ne démarre pas l'écran à distance.
 */
class RemoteAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile var instance: RemoteAccessibilityService? = null
    }

    private val worker = Executors.newSingleThreadExecutor()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    /**
     * Capture l'écran, le réduit à `maxSide` pixels de côté (sans l'agrandir) et le compresse en WebP ou en JPEG.
     * `done` est appelé sur un thread de travail, avec null en cas d'échec.
     */
    fun capture(maxSide: Int, quality: Int, webp: Boolean, done: (ByteArray?) -> Unit) {
        try {
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                worker,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                        try {
                            val buffer = result.hardwareBuffer
                            val hardware = Bitmap.wrapHardwareBuffer(buffer, result.colorSpace)
                            if (hardware == null) {
                                buffer.close()
                                done(null)
                                return
                            }
                            val soft = hardware.copy(Bitmap.Config.ARGB_8888, false)
                            hardware.recycle()
                            buffer.close()
                            val scale = minOf(1f, maxSide.toFloat() / maxOf(soft.width, soft.height))
                            val small = if (scale >= 1f) soft else Bitmap.createScaledBitmap(
                                soft,
                                (soft.width * scale).toInt().coerceAtLeast(1),
                                (soft.height * scale).toInt().coerceAtLeast(1),
                                true
                            )
                            val format = if (webp && Build.VERSION.SDK_INT >= 30) {
                                Bitmap.CompressFormat.WEBP_LOSSY
                            } else {
                                Bitmap.CompressFormat.JPEG
                            }
                            val out = ByteArrayOutputStream()
                            small.compress(format, quality.coerceIn(10, 95), out)
                            done(out.toByteArray())
                        } catch (e: Exception) {
                            done(null)
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        done(null)
                    }
                }
            )
        } catch (e: Exception) {
            done(null)
        }
    }

    fun tap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        dispatch(path, 50)
    }

    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        dispatch(path, durationMs)
    }

    private fun dispatch(path: Path, durationMs: Long) {
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(1, 2000))
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    /** 0 = retour, 1 = accueil, 2 = applications récentes, 3 = notifications. */
    fun navigate(kind: Int) {
        when (kind) {
            0 -> performGlobalAction(GLOBAL_ACTION_BACK)
            1 -> performGlobalAction(GLOBAL_ACTION_HOME)
            2 -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            3 -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        }
    }
}
