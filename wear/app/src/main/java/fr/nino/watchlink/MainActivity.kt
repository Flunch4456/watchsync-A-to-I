package fr.nino.watchlink

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

class MainActivity : Activity() {

    private lateinit var bpmText: TextView
    private lateinit var statusText: TextView
    private lateinit var toggle: Button

    private val permissions = arrayOf(
        Manifest.permission.BODY_SENSORS,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.BLUETOOTH_ADVERTISE,
        Manifest.permission.POST_NOTIFICATIONS
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val pad = (24 * resources.displayMetrics.density).toInt()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(pad, pad, pad, pad)
        }

        bpmText = TextView(this).apply {
            text = "--"
            textSize = 44f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        statusText = TextView(this).apply {
            text = "Arrêté"
            textSize = 14f
            setTextColor(Color.LTGRAY)
            gravity = Gravity.CENTER
        }
        toggle = Button(this).apply {
            setOnClickListener { onToggle() }
        }

        column.addView(bpmText, wrap())
        column.addView(statusText, wrap())
        column.addView(toggle, wrap())

        setContentView(ScrollView(this).apply { addView(column) })
        refreshButton()
    }

    override fun onResume() {
        super.onResume()
        HeartRateService.onBpm = { bpm -> runOnUiThread { bpmText.text = "$bpm" } }
        HeartRateService.onStatus = { s -> runOnUiThread { statusText.text = s } }
        refreshButton()
    }

    override fun onPause() {
        HeartRateService.onBpm = null
        HeartRateService.onStatus = null
        super.onPause()
    }

    private fun onToggle() {
        if (HeartRateService.running) {
            stopService(Intent(this, HeartRateService::class.java))
            bpmText.text = "--"
            statusText.text = "Arrêté"
            // `running` repasse à false dans onDestroy du service, on met le bouton à jour tout de suite
            toggle.text = "Démarrer"
        } else if (hasAllPermissions()) {
            startForegroundService(Intent(this, HeartRateService::class.java))
            toggle.text = "Arrêter"
            statusText.text = "Démarrage…"
        } else {
            requestPermissions(permissions, 1)
        }
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)
        if (hasAllPermissions()) {
            onToggle()
        } else {
            statusText.text = "Permissions refusées"
        }
    }

    private fun hasAllPermissions() = permissions.all {
        checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    private fun refreshButton() {
        toggle.text = if (HeartRateService.running) "Arrêter" else "Démarrer"
    }

    private fun wrap() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    )
}
