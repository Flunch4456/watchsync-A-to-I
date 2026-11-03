package fr.nino.watchlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Service au premier plan : lit le capteur cardiaque de la montre et le diffuse
 * en Bluetooth Low Energy. Il expose trois services :
 *  - Heart Rate (0x180D) : les battements, lus nativement par l'iPhone
 *  - Battery (0x180F)    : le niveau de batterie de la montre
 *  - un service de commandes maison : sonnerie, seuils d'alerte, démarrage auto
 *
 * Android ne laisse tourner un capteur en continu, écran éteint, que dans un
 * service au premier plan, d'où la notification permanente et le wake lock.
 */
class HeartRateService : Service(), SensorEventListener {

    companion object {
        private const val TAG = "WatchLink"
        private const val CHANNEL_ID = "watchlink"
        private const val NOTIF_ID = 1

        const val ACTION_STOP_RING = "fr.nino.watchlink.STOP_RING"
        const val PREFS = "watchlink"
        const val KEY_AUTOSTART = "autostart"
        private const val KEY_ALERT_LOW = "alert_lo"
        private const val KEY_ALERT_HIGH = "alert_hi"
        private const val KEY_ALERT_VIBRATE = "alert_vibrate"

        private fun std(short: String): UUID =
            UUID.fromString("0000$short-0000-1000-8000-00805f9b34fb")

        val HR_SERVICE: UUID = std("180d")
        val HR_MEASUREMENT: UUID = std("2a37")
        val BATTERY_SERVICE: UUID = std("180f")
        val BATTERY_LEVEL: UUID = std("2a19")
        val CCCD: UUID = std("2902")

        // Service de commandes maison (l'iPhone écrit dedans)
        val CTRL_SERVICE: UUID = UUID.fromString("9f2b0001-6c1d-4a57-8e3b-5d6a7c8e9f10")
        val CTRL_COMMAND: UUID = UUID.fromString("9f2b0002-6c1d-4a57-8e3b-5d6a7c8e9f10")

        // Commandes : premier octet de l'écriture
        private const val CMD_RING_START = 0x01
        private const val CMD_RING_STOP = 0x02
        private const val CMD_SET_ALERT = 0x10 // [0x10, bas, haut, flags] (0 = désactivé, flags bit0 = vibration)
        private const val CMD_SET_AUTOSTART = 0x30 // [0x30, 0 ou 1]

        @Volatile var running: Boolean = false
        /** Appelés depuis le service pour mettre à jour l'écran. */
        @Volatile var onBpm: ((Int) -> Unit)? = null
        @Volatile var onStatus: ((String) -> Unit)? = null
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var sensorManager: SensorManager
    private lateinit var btManager: BluetoothManager
    private var gattServer: BluetoothGattServer? = null
    private var hrCharacteristic: BluetoothGattCharacteristic? = null
    private var batteryCharacteristic: BluetoothGattCharacteristic? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val pendingServices = ArrayDeque<BluetoothGattService>()
    private val hrSubscribers = CopyOnWriteArraySet<BluetoothDevice>()
    private val batterySubscribers = CopyOnWriteArraySet<BluetoothDevice>()
    private var lastBpm = 0
    private var lastAlertAt = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private var player: MediaPlayer? = null
    private var savedAlarmVolume = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_RING) {
            stopRing()
            if (!running) stopSelf()
            return START_STICKY
        }
        startInForeground()
        if (!running) {
            running = true
            acquireWakeLock()
            startSensor()
            startBle()
            handler.post(batteryRunnable)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(batteryRunnable)
        stopRing()
        sensorManager.unregisterListener(this)
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (e: SecurityException) {
            Log.w(TAG, "stopAdvertising: $e")
        }
        try {
            gattServer?.close()
        } catch (e: SecurityException) {
            Log.w(TAG, "close gatt: $e")
        }
        gattServer = null
        hrSubscribers.clear()
        batterySubscribers.clear()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        status("Arrêté")
        super.onDestroy()
    }

    // --- Notification obligatoire pour un service au premier plan -----------------

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "WatchLink", NotificationManager.IMPORTANCE_LOW)
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("WatchLink")
            .setContentText("Diffusion du rythme cardiaque")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .build()
        startForeground(
            NOTIF_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        )
    }

    /** Garde le processeur éveillé pour que la mesure continue écran éteint. */
    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "watchlink:heartrate").also {
            it.setReferenceCounted(false)
            it.acquire()
        }
    }

    // --- Capteur cardiaque --------------------------------------------------------

    private fun startSensor() {
        val sensor = sensorManager.getDefaultSensor(Sensor.TYPE_HEART_RATE)
        if (sensor == null) {
            status("Pas de capteur cardiaque")
            return
        }
        try {
            sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        } catch (e: SecurityException) {
            status("Permission capteurs refusée")
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        val bpm = event.values.firstOrNull()?.toInt() ?: return
        if (bpm <= 0) return // 0 = pas de mesure valide (montre mal placée, capteur en démarrage)
        lastBpm = bpm
        onBpm?.invoke(bpm)
        notifyHeartRate(bpm)
        checkAlert(bpm)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    // --- Alerte de rythme (vibration) ---------------------------------------------

    private fun checkAlert(bpm: Int) {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ALERT_VIBRATE, true)) return
        val low = prefs.getInt(KEY_ALERT_LOW, 0)
        val high = prefs.getInt(KEY_ALERT_HIGH, 0)
        val outOfRange = (high > 0 && bpm > high) || (low > 0 && bpm < low)
        val now = SystemClock.elapsedRealtime()
        // Une alerte au maximum par minute pour ne pas vibrer en continu
        if (outOfRange && now - lastAlertAt > 60_000) {
            lastAlertAt = now
            vibrate(longArrayOf(0, 400, 200, 400, 200, 400), -1)
        }
    }

    private fun vibrate(pattern: LongArray, repeat: Int) {
        try {
            val vibrator: Vibrator = getSystemService(VibratorManager::class.java).defaultVibrator
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, repeat))
        } catch (e: Exception) {
            Log.w(TAG, "vibration: $e")
        }
    }

    // --- Sonnerie pour retrouver la montre ---------------------------------------

    private val stopRingRunnable = Runnable { stopRing() }

    private fun startRing() {
        stopRing()
        try {
            val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            savedAlarmVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
            audio.setStreamVolume(
                AudioManager.STREAM_ALARM,
                audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0
            )
            val uri: Uri? = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            if (uri == null) throw IllegalStateException("aucune sonnerie disponible")
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(this@HeartRateService, uri)
                isLooping = true
                prepare()
                start()
            }
            vibrate(longArrayOf(0, 600, 400), 0)
            status("Sonnerie en cours")
        } catch (e: Exception) {
            Log.e(TAG, "sonnerie: $e")
        }
        // Arrêt automatique au bout d'une minute
        handler.removeCallbacks(stopRingRunnable)
        handler.postDelayed(stopRingRunnable, 60_000)
    }

    private fun stopRing() {
        handler.removeCallbacks(stopRingRunnable)
        player?.let {
            try {
                it.stop()
            } catch (e: Exception) {
                Log.w(TAG, "stop player: $e")
            }
            it.release()
        }
        player = null
        try {
            getSystemService(VibratorManager::class.java).defaultVibrator.cancel()
        } catch (e: Exception) {
            Log.w(TAG, "cancel vibration: $e")
        }
        if (savedAlarmVolume >= 0) {
            try {
                val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audio.setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVolume, 0)
            } catch (e: Exception) {
                Log.w(TAG, "restore volume: $e")
            }
            savedAlarmVolume = -1
        }
    }

    // --- Batterie -----------------------------------------------------------------

    private fun batteryPercent(): Int {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).coerceIn(0, 100)
    }

    private val batteryRunnable = object : Runnable {
        override fun run() {
            notifyBattery()
            handler.postDelayed(this, 60_000)
        }
    }

    private fun notifyBattery() {
        val characteristic = batteryCharacteristic ?: return
        val value = byteArrayOf(batteryPercent().toByte())
        for (device in batterySubscribers) {
            try {
                gattServer?.notifyCharacteristicChanged(device, characteristic, false, value)
            } catch (e: SecurityException) {
                Log.w(TAG, "notify batterie: $e")
            }
        }
    }

    // --- Serveur Bluetooth -------------------------------------------------------

    private fun cccd() = BluetoothGattDescriptor(
        CCCD,
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
    )

    private fun startBle() {
        val adapter = btManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            status("Bluetooth désactivé")
            return
        }
        try {
            gattServer = btManager.openGattServer(this, gattCallback)

            val hrService = BluetoothGattService(HR_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val measurement = BluetoothGattCharacteristic(
                HR_MEASUREMENT,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                0
            )
            measurement.addDescriptor(cccd())
            hrService.addCharacteristic(measurement)
            hrCharacteristic = measurement

            val batteryService =
                BluetoothGattService(BATTERY_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val level = BluetoothGattCharacteristic(
                BATTERY_LEVEL,
                BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            level.addDescriptor(cccd())
            batteryService.addCharacteristic(level)
            batteryCharacteristic = level

            val controlService =
                BluetoothGattService(CTRL_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val command = BluetoothGattCharacteristic(
                CTRL_COMMAND,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            controlService.addCharacteristic(command)

            // Android n'accepte qu'un addService à la fois : on les enchaîne
            // via onServiceAdded, puis on lance l'annonce quand le dernier est prêt.
            pendingServices.clear()
            pendingServices.addAll(listOf(hrService, batteryService, controlService))
            addNextService()
        } catch (e: SecurityException) {
            status("Permission Bluetooth refusée")
        }
    }

    private fun addNextService() {
        val next = pendingServices.removeFirstOrNull()
        if (next == null) {
            startAdvertising()
            return
        }
        try {
            gattServer?.addService(next)
        } catch (e: SecurityException) {
            status("Permission Bluetooth refusée")
        }
    }

    private fun startAdvertising() {
        try {
            advertiser = btManager.adapter.bluetoothLeAdvertiser
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .setTimeout(0)
                .build()
            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(ParcelUuid(HR_SERVICE))
                .build()
            // Le nom va dans la réponse de scan (le paquet principal est limité à 31 octets)
            val scanResponse = AdvertiseData.Builder()
                .setIncludeDeviceName(true)
                .build()
            advertiser?.startAdvertising(settings, data, scanResponse, advertiseCallback)
            status("En attente de l'iPhone…")
        } catch (e: SecurityException) {
            status("Permission Bluetooth refusée")
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "Annonce BLE démarrée")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "Annonce BLE échouée: $errorCode")
            status("Erreur annonce BLE ($errorCode)")
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {

        override fun onServiceAdded(gattStatus: Int, service: BluetoothGattService) {
            handler.post { addNextService() }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, gattStatus: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                hrSubscribers.remove(device)
                batterySubscribers.remove(device)
                status("Déconnecté, en attente…")
            } else if (newState == BluetoothProfile.STATE_CONNECTED) {
                status("iPhone connecté")
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (descriptor.uuid == CCCD) {
                val enabled = value.isNotEmpty() && value[0].toInt() != 0
                when (descriptor.characteristic.uuid) {
                    HR_MEASUREMENT -> {
                        if (enabled) {
                            hrSubscribers.add(device)
                            status("iPhone abonné")
                            if (lastBpm > 0) notifyHeartRate(lastBpm)
                        } else {
                            hrSubscribers.remove(device)
                        }
                    }
                    BATTERY_LEVEL -> {
                        if (enabled) {
                            batterySubscribers.add(device)
                            handler.post { notifyBattery() }
                        } else {
                            batterySubscribers.remove(device)
                        }
                    }
                }
            }
            if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, value)
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor
        ) {
            val subscribed = when (descriptor.characteristic.uuid) {
                HR_MEASUREMENT -> hrSubscribers.contains(device)
                BATTERY_LEVEL -> batterySubscribers.contains(device)
                else -> false
            }
            val value = if (subscribed)
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            else
                BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            respond(device, requestId, BluetoothGatt.GATT_SUCCESS, value)
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == BATTERY_LEVEL) {
                respond(device, requestId, BluetoothGatt.GATT_SUCCESS, byteArrayOf(batteryPercent().toByte()))
            } else {
                respond(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, null)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (characteristic.uuid == CTRL_COMMAND) {
                handler.post { handleCommand(value) }
                if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, value)
            } else if (responseNeeded) {
                respond(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, null)
            }
        }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, result: Int, value: ByteArray?) {
        try {
            gattServer?.sendResponse(device, requestId, result, 0, value)
        } catch (e: SecurityException) {
            Log.w(TAG, "sendResponse: $e")
        }
    }

    /** Commandes envoyées par l'iPhone. */
    private fun handleCommand(value: ByteArray) {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        when (value.firstOrNull()?.toInt()) {
            CMD_RING_START -> startRing()
            CMD_RING_STOP -> {
                stopRing()
                status("iPhone connecté")
            }
            CMD_SET_ALERT -> if (value.size >= 4) {
                prefs.edit()
                    .putInt(KEY_ALERT_LOW, value[1].toInt() and 0xFF)
                    .putInt(KEY_ALERT_HIGH, value[2].toInt() and 0xFF)
                    .putBoolean(KEY_ALERT_VIBRATE, (value[3].toInt() and 0x01) != 0)
                    .apply()
            }
            CMD_SET_AUTOSTART -> if (value.size >= 2) {
                prefs.edit().putBoolean(KEY_AUTOSTART, value[1].toInt() != 0).apply()
            }
        }
    }

    private fun notifyHeartRate(bpm: Int) {
        val characteristic = hrCharacteristic ?: return
        // Format "Heart Rate Measurement" : octet de flags (0 = valeur sur 8 bits), puis le BPM
        val payload = byteArrayOf(0x00, bpm.coerceIn(0, 255).toByte())
        for (device in hrSubscribers) {
            try {
                gattServer?.notifyCharacteristicChanged(device, characteristic, false, payload)
            } catch (e: SecurityException) {
                Log.w(TAG, "notify: $e")
            }
        }
    }

    private fun status(text: String) {
        onStatus?.invoke(text)
    }
}
