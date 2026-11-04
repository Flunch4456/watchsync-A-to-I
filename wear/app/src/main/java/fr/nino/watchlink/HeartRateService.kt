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
import android.bluetooth.BluetoothStatusCodes
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
import android.util.Base64
import android.util.Log
import java.time.LocalDate
import java.time.LocalTime
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Service au premier plan : lit les capteurs de la montre et les diffuse en Bluetooth Low Energy.
 * Il expose trois services :
 *  - Heart Rate (0x180D) : les battements, lus nativement par l'iPhone
 *  - Battery (0x180F)    : le niveau de batterie de la montre
 *  - un service maison   : liaison par code, commandes, événements, synchronisation du journal
 *
 * Aucun iPhone ne reçoit de données tant qu'il ne s'est pas lié avec le code affiché sur la montre.
 * Android ne laisse tourner un capteur en continu, écran éteint, que dans un
 * service au premier plan, d'où la notification permanente et le wake lock.
 */
class HeartRateService : Service(), SensorEventListener {

    companion object {
        private const val TAG = "WatchLink"
        private const val CHANNEL_ID = "watchlink"
        private const val NOTIF_ID = 1

        const val ACTION_STOP_RING = "fr.nino.watchlink.STOP_RING"
        const val ACTION_PAIR = "fr.nino.watchlink.PAIR"
        const val ACTION_FORGET_PAIRING = "fr.nino.watchlink.FORGET_PAIRING"
        const val ACTION_PHONE_ALERT = "fr.nino.watchlink.PHONE_ALERT"
        const val EXTRA_KIND = "kind"

        const val PREFS = "watchlink"
        const val KEY_AUTOSTART = "autostart"
        private const val KEY_ALERT_LOW = "alert_lo"
        private const val KEY_ALERT_HIGH = "alert_hi"
        private const val KEY_ALERT_VIBRATE = "alert_vibrate"
        private const val KEY_HR_INTERVAL = "hr_interval"
        private const val KEY_STEP_DAY = "step_day"
        private const val KEY_STEP_BASE = "step_base"
        private const val KEY_STEP_CARRY = "step_carry"
        private const val KEY_STEP_LAST = "step_last"
        private const val KEY_LTK = "ltk"
        private const val KEY_MIRROR = "mirror_notifications"
        private const val KEY_MOVE_MIN = "move_reminder_min"
        private const val KEY_APP_MASK = "app_mask"
        private const val KEY_QUIET_ON = "quiet_on"
        private const val KEY_QUIET_START = "quiet_start"
        private const val KEY_QUIET_END = "quiet_end"

        private fun std(short: String): UUID =
            UUID.fromString("0000$short-0000-1000-8000-00805f9b34fb")

        val HR_SERVICE: UUID = std("180d")
        val HR_MEASUREMENT: UUID = std("2a37")
        val BATTERY_SERVICE: UUID = std("180f")
        val BATTERY_LEVEL: UUID = std("2a19")
        val CCCD: UUID = std("2902")

        // Service maison
        val CTRL_SERVICE: UUID = UUID.fromString("9f2b0001-6c1d-4a57-8e3b-5d6a7c8e9f10")
        val CTRL_COMMAND: UUID = UUID.fromString("9f2b0002-6c1d-4a57-8e3b-5d6a7c8e9f10")
        val CTRL_EVENT: UUID = UUID.fromString("9f2b0003-6c1d-4a57-8e3b-5d6a7c8e9f10")
        val CTRL_SYNC: UUID = UUID.fromString("9f2b0004-6c1d-4a57-8e3b-5d6a7c8e9f10")
        val CTRL_AUTH: UUID = UUID.fromString("9f2b0005-6c1d-4a57-8e3b-5d6a7c8e9f10")

        // Commandes (iPhone vers montre) : premier octet de l'écriture
        private const val CMD_RING_START = 0x01 // sonnerie + vibration
        private const val CMD_RING_STOP = 0x02 // coupe sonnerie et vibration
        private const val CMD_VIBRATE_START = 0x03 // vibration seule
        private const val CMD_SET_ALERT = 0x10 // [0x10, bas, haut, flags] (0 = désactivé, flags bit0 = vibration)
        private const val CMD_SET_AUTOSTART = 0x30 // [0x30, 0 ou 1]
        private const val CMD_SET_INTERVAL = 0x40 // [0x40, hi, lo] secondes entre deux mesures (0 = désactivée)
        private const val CMD_SET_MIRROR = 0x60 // [0x60, 0 ou 1] affiche les notifications de l'iPhone
        private const val CMD_SET_MOVE = 0x70 // [0x70, hi, lo] minutes sans bouger avant le rappel (0 = désactivé)
        private const val CMD_SET_APPS = 0x71 // [0x71, hi, lo] apps autorisées (un bit par app, bit 15 = les autres)
        private const val CMD_SET_QUIET = 0x72 // [0x72, actif, heure début, heure fin]
        private const val CMD_SYNC_REQUEST = 0x50 // [0x50, 4 octets] envoie tout ce qui est plus récent (secondes)

        // Événements (montre vers iPhone) : premier octet de la notification
        private const val EVENT_STEPS = 0x01 // [0x01, pas du jour sur 4 octets]
        private const val EVENT_WORN = 0x02 // [0x02, 1 = portée, 0 = retirée]
        private const val EVENT_PHONE_ALERT = 0x03 // [0x03, 1 = sonner, 2 = vibrer, 0 = annuler]

        // Synchronisation : types de paquets
        private const val SYNC_HEART_RATE = 0x01
        private const val SYNC_BATTERY = 0x02
        private const val SYNC_STEPS = 0x03
        private const val SYNC_END = 0xFF

        // Liaison : réponses
        private const val AUTH_READ_UNPAIRED = 0x10
        private const val AUTH_READ_PAIRED = 0x11
        private const val AUTH_DENIED = 0x20
        private const val AUTH_OK = 0x21
        private const val AUTH_PAIRED = 0x22
        private const val PAIRING_DURATION_MS = 120_000L
        private const val PAIRING_MAX_ATTEMPTS = 5

        /** Au-delà de ce délai (en secondes), on mesure par à-coups au lieu de en continu. */
        private const val CONTINUOUS_MAX_SEC = 5
        private const val MEASURE_TIMEOUT_MS = 40_000L

        @Volatile var running: Boolean = false
        /** Code de liaison affiché sur la montre, null quand aucune liaison n'est en cours. */
        @Volatile var pairingCode: String? = null
        /** Appelés depuis le service pour mettre à jour l'écran. */
        @Volatile var onBpm: ((Int) -> Unit)? = null
        @Volatile var onStatus: ((String) -> Unit)? = null
        @Volatile var onPairingCode: ((String?) -> Unit)? = null
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var sensorManager: SensorManager
    private lateinit var btManager: BluetoothManager
    private lateinit var sampleLog: SampleLog
    private var gattServer: BluetoothGattServer? = null
    private var hrCharacteristic: BluetoothGattCharacteristic? = null
    private var batteryCharacteristic: BluetoothGattCharacteristic? = null
    private var eventCharacteristic: BluetoothGattCharacteristic? = null
    private var syncCharacteristic: BluetoothGattCharacteristic? = null
    private var authCharacteristic: BluetoothGattCharacteristic? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val pendingServices = ArrayDeque<BluetoothGattService>()

    private val hrSubscribers = CopyOnWriteArraySet<BluetoothDevice>()
    private val batterySubscribers = CopyOnWriteArraySet<BluetoothDevice>()
    private val eventSubscribers = CopyOnWriteArraySet<BluetoothDevice>()

    // Liaison
    private val authorized = CopyOnWriteArraySet<BluetoothDevice>()
    private val authNonces = ConcurrentHashMap<BluetoothDevice, ByteArray>()
    private var pairingExpiresAt = 0L
    private var pairingAttempts = 0

    // Synchronisation du journal
    private val syncQueue = ConcurrentLinkedDeque<ByteArray>()
    private var syncDevice: BluetoothDevice? = null
    private var syncInFlight = false
    private var currentMtu = 23
    private var ancs: AncsClient? = null
    private var lastMoveAt = SystemClock.elapsedRealtime()
    private var lastMoveSteps = -1

    private var lastBpm = 0
    private var lastAlertAt = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private var player: MediaPlayer? = null
    private var savedAlarmVolume = -1

    private var hrSensor: Sensor? = null
    private var hrActive = false
    private var onBody = true
    private var stepsToday = 0
    private var lastStepNotifyAt = 0L

    // Journal : dernières écritures
    private var lastLoggedHr = 0L
    private var lastLoggedBatteryAt = 0L
    private var lastLoggedBattery = -1
    private var lastLoggedStepsAt = 0L
    private var lastLoggedSteps = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        sampleLog = SampleLog(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_RING -> {
                stopRing()
                if (!running) stopSelf()
                return START_STICKY
            }
            ACTION_PAIR -> {
                if (running) startPairing() else stopSelf()
                return START_STICKY
            }
            ACTION_FORGET_PAIRING -> {
                forgetPairing()
                if (!running) stopSelf()
                return START_STICKY
            }
            ACTION_PHONE_ALERT -> {
                if (running) sendPhoneAlert(intent.getIntExtra(EXTRA_KIND, 0)) else stopSelf()
                return START_STICKY
            }
        }
        startInForeground()
        if (!running) {
            running = true
            acquireWakeLock()
            sampleLog.prune(System.currentTimeMillis() / 1000)
            startSensors()
            startBle()
            handler.post(batteryRunnable)
            handler.postDelayed(moveRunnable, 60_000)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacksAndMessages(null)
        stopRing()
        endPairing()
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
        eventSubscribers.clear()
        authorized.clear()
        authNonces.clear()
        syncQueue.clear()
        syncDevice = null
        ancs?.stop()
        ancs = null
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

    // --- Capteurs -----------------------------------------------------------------

    private fun startSensors() {
        hrSensor = sensorManager.getDefaultSensor(Sensor.TYPE_HEART_RATE)

        // Détection "montre au poignet" : quand elle est retirée, on coupe la mesure cardiaque
        val offBody = sensorManager.getDefaultSensor(Sensor.TYPE_LOW_LATENCY_OFFBODY_DETECT)
        if (offBody != null) {
            try {
                sensorManager.registerListener(this, offBody, SensorManager.SENSOR_DELAY_NORMAL)
            } catch (e: SecurityException) {
                Log.w(TAG, "détection du port: permission refusée")
            }
        }

        if (hrSensor == null) {
            status("Pas de capteur cardiaque")
        } else {
            applyInterval()
        }

        // Compteur de pas : nécessite la permission "activité physique", sans elle on continue sans les pas
        val stepSensor = sensorManager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
        if (stepSensor != null) {
            try {
                sensorManager.registerListener(this, stepSensor, SensorManager.SENSOR_DELAY_NORMAL)
            } catch (e: SecurityException) {
                Log.w(TAG, "pas: permission refusée")
            }
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_HEART_RATE -> onHeartRate(event)
            Sensor.TYPE_STEP_COUNTER -> onStepCounter(event.values[0].toLong())
            Sensor.TYPE_LOW_LATENCY_OFFBODY_DETECT -> onOffBody(event.values[0] >= 0.5f)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    // --- Montre portée ou retirée -------------------------------------------------

    private fun onOffBody(worn: Boolean) {
        if (worn == onBody) return
        onBody = worn
        notifyWorn()
        if (worn) {
            lastMoveAt = SystemClock.elapsedRealtime()
            status("Montre portée")
            applyInterval()
        } else {
            // Pas de mesure cardiaque tant que la montre n'est pas au poignet
            handler.removeCallbacks(dutyRunnable)
            handler.removeCallbacks(measureTimeoutRunnable)
            stopHr()
            status("Montre retirée : mesure en pause")
        }
    }

    private fun notifyWorn() {
        sendEvent(byteArrayOf(EVENT_WORN.toByte(), if (onBody) 1 else 0))
    }

    // --- Rythme cardiaque : mesure continue ou par à-coups ------------------------

    private fun intervalSec(): Int =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_HR_INTERVAL, 1)

    private val dutyRunnable: Runnable = Runnable {
        if (onBody) {
            startHr()
            handler.postDelayed(measureTimeoutRunnable, MEASURE_TIMEOUT_MS)
        }
    }

    /** Si aucune mesure valide n'arrive (montre mal portée), on coupe le capteur et on réessaiera plus tard. */
    private val measureTimeoutRunnable: Runnable = Runnable {
        stopHr()
        if (onBody) handler.postDelayed(dutyRunnable, intervalSec() * 1000L)
    }

    private fun startHr() {
        val sensor = hrSensor ?: return
        if (hrActive || !onBody) return
        try {
            sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
            hrActive = true
        } catch (e: SecurityException) {
            status("Permission capteurs refusée")
        }
    }

    private fun stopHr() {
        val sensor = hrSensor ?: return
        if (!hrActive) return
        sensorManager.unregisterListener(this, sensor)
        hrActive = false
    }

    /** Applique le réglage d'intervalle : 0 = désactivé, 1 à 5 s = continu, au-delà = une mesure toutes les N secondes. */
    private fun applyInterval() {
        handler.removeCallbacks(dutyRunnable)
        handler.removeCallbacks(measureTimeoutRunnable)
        if (!onBody) {
            stopHr()
            return
        }
        val seconds = intervalSec()
        when {
            seconds <= 0 -> {
                stopHr()
                status("Mesure cardiaque désactivée")
            }
            seconds <= CONTINUOUS_MAX_SEC -> startHr()
            else -> {
                startHr()
                handler.postDelayed(measureTimeoutRunnable, MEASURE_TIMEOUT_MS)
            }
        }
    }

    private fun onHeartRate(event: SensorEvent) {
        if (!onBody) return
        // Pas de contact avec la peau : la valeur n'a aucun sens
        if (event.accuracy == SensorManager.SENSOR_STATUS_NO_CONTACT) return
        val bpm = event.values.firstOrNull()?.toInt() ?: return
        if (bpm <= 0) return // 0 = pas de mesure valide (capteur en démarrage)
        lastBpm = bpm
        onBpm?.invoke(bpm)
        notifyHeartRate(bpm)
        checkAlert(bpm)
        logHeartRate(bpm)

        val seconds = intervalSec()
        if (seconds > CONTINUOUS_MAX_SEC) {
            // Mesure par à-coups : une valeur suffit, on coupe le capteur jusqu'à la prochaine
            handler.removeCallbacks(measureTimeoutRunnable)
            stopHr()
            handler.removeCallbacks(dutyRunnable)
            handler.postDelayed(dutyRunnable, seconds * 1000L)
        }
    }

    // --- Journal hors connexion ---------------------------------------------------

    private fun logHeartRate(bpm: Int) {
        val now = System.currentTimeMillis() / 1000
        if (now - lastLoggedHr >= 10) {
            lastLoggedHr = now
            sampleLog.appendHeartRate(now, bpm)
        }
    }

    private fun logBattery(percent: Int) {
        val now = System.currentTimeMillis() / 1000
        if (percent != lastLoggedBattery || now - lastLoggedBatteryAt >= 600) {
            lastLoggedBattery = percent
            lastLoggedBatteryAt = now
            sampleLog.appendBattery(now, percent)
        }
    }

    private fun logSteps(steps: Int) {
        val now = System.currentTimeMillis() / 1000
        if (steps != lastLoggedSteps && now - lastLoggedStepsAt >= 300) {
            lastLoggedSteps = steps
            lastLoggedStepsAt = now
            sampleLog.appendSteps(LocalDate.now().toEpochDay(), steps)
        }
    }

    // --- Pas ----------------------------------------------------------------------

    /**
     * Le capteur donne le total de pas depuis le dernier redémarrage de la montre.
     * On en déduit les pas du jour, en gardant le cumul quand la montre redémarre.
     */
    private fun onStepCounter(counter: Long) {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val today = LocalDate.now().toString()
        var base = prefs.getLong(KEY_STEP_BASE, counter)
        var carry = prefs.getLong(KEY_STEP_CARRY, 0)
        val last = prefs.getLong(KEY_STEP_LAST, counter)

        if (prefs.getString(KEY_STEP_DAY, null) != today) {
            // Nouveau jour : on repart de zéro
            base = counter
            carry = 0
        } else if (counter < last) {
            // La montre a redémarré : le compteur est reparti de zéro, on garde ce qui était déjà compté
            carry += last - base
            base = counter
        }
        prefs.edit()
            .putString(KEY_STEP_DAY, today)
            .putLong(KEY_STEP_BASE, base)
            .putLong(KEY_STEP_CARRY, carry)
            .putLong(KEY_STEP_LAST, counter)
            .apply()

        stepsToday = (carry + counter - base).coerceAtLeast(0).toInt()
        if (lastMoveSteps < 0 || stepsToday < lastMoveSteps) {
            lastMoveSteps = stepsToday
        } else if (stepsToday - lastMoveSteps >= 30) {
            lastMoveSteps = stepsToday
            lastMoveAt = SystemClock.elapsedRealtime()
        }
        logSteps(stepsToday)

        val now = SystemClock.elapsedRealtime()
        if (now - lastStepNotifyAt > 15_000) {
            lastStepNotifyAt = now
            notifySteps()
        }
    }

    private fun notifySteps() {
        sendEvent(byteArrayOf(EVENT_STEPS.toByte()) + le32(stepsToday.toLong()))
    }

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

    // --- Sonnerie et vibration pour retrouver la montre ---------------------------

    private val stopRingRunnable: Runnable = Runnable { stopRing() }

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

    /** Vibration seule, sans son. */
    private fun startVibrateOnly() {
        stopRing()
        vibrate(longArrayOf(0, 600, 400), 0)
        status("Vibration en cours")
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

    /** Depuis la montre : fait sonner (1), vibrer (2) ou arrête (0) l'iPhone. */
    private fun sendPhoneAlert(kind: Int) {
        if (eventSubscribers.isEmpty()) {
            status("iPhone non connecté")
            return
        }
        sendEvent(byteArrayOf(EVENT_PHONE_ALERT.toByte(), kind.toByte()))
        status(
            when (kind) {
                1 -> "iPhone : sonnerie demandée"
                2 -> "iPhone : vibration demandée"
                else -> "iPhone : alerte annulée"
            }
        )
    }

    // --- Batterie -----------------------------------------------------------------

    private fun batteryPercent(): Int {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).coerceIn(0, 100)
    }

    private val batteryRunnable: Runnable = object : Runnable {
        override fun run() {
            logBattery(batteryPercent())
            notifyBattery()
            handler.postDelayed(this, 60_000)
        }
    }

    private fun notifyBattery() {
        val characteristic = batteryCharacteristic ?: return
        if (syncActive()) return
        val value = byteArrayOf(batteryPercent().toByte())
        for (device in batterySubscribers) {
            try {
                gattServer?.notifyCharacteristicChanged(device, characteristic, false, value)
            } catch (e: SecurityException) {
                Log.w(TAG, "notify batterie: $e")
            }
        }
    }

    // --- Liaison par code ---------------------------------------------------------

    private fun loadLtk(): ByteArray? =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_LTK, null)
            ?.let { Base64.decode(it, Base64.NO_WRAP) }

    private fun saveLtk(key: ByteArray) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_LTK, Base64.encodeToString(key, Base64.NO_WRAP))
            .apply()
    }

    private val endPairingRunnable: Runnable = Runnable { endPairing() }

    /** Génère un code à 6 chiffres, affiché sur la montre et valable 2 minutes. */
    private fun startPairing() {
        val code = Crypto.sixDigitCode()
        pairingCode = code
        pairingAttempts = 0
        pairingExpiresAt = SystemClock.elapsedRealtime() + PAIRING_DURATION_MS
        onPairingCode?.invoke(code)
        status("Liaison : saisis le code sur l'iPhone")
        handler.removeCallbacks(endPairingRunnable)
        handler.postDelayed(endPairingRunnable, PAIRING_DURATION_MS)
    }

    private fun endPairing() {
        handler.removeCallbacks(endPairingRunnable)
        pairingCode = null
        onPairingCode?.invoke(null)
    }

    private fun forgetPairing() {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY_LTK).apply()
        authorized.clear()
        hrSubscribers.clear()
        batterySubscribers.clear()
        eventSubscribers.clear()
        status("Liaison effacée")
    }

    private fun notifyAuth(device: BluetoothDevice, payload: ByteArray) {
        val characteristic = authCharacteristic ?: return
        try {
            gattServer?.notifyCharacteristicChanged(device, characteristic, false, payload)
        } catch (e: SecurityException) {
            Log.w(TAG, "notify liaison: $e")
        }
    }

    /**
     * Écriture de l'iPhone sur la caractéristique de liaison :
     *  [0x01, preuve] : l'iPhone se connaît déjà, il prouve qu'il a la clé
     *  [0x02, preuve] : l'iPhone envoie le code saisi, sous forme d'une preuve (le code ne circule pas)
     * La montre répond par une notification : DENIED, OK, ou PAIRED suivie de la clé chiffrée.
     */
    private fun handleAuth(device: BluetoothDevice, value: ByteArray) {
        val denied = byteArrayOf(AUTH_DENIED.toByte())
        val nonce = authNonces[device]
        if (nonce == null || value.size < 17) {
            notifyAuth(device, denied)
            return
        }
        val proof = value.copyOfRange(1, 17)

        when (value[0].toInt()) {
            0x01 -> {
                val ltk = loadLtk()
                if (ltk != null && Crypto.constantTimeEquals(proof, Crypto.hmac16(ltk, nonce))) {
                    authorized.add(device)
                    authNonces.remove(device)
                    notifyAuth(device, byteArrayOf(AUTH_OK.toByte()))
                    status("iPhone lié et connecté")
                    applyMirror(device)
                } else {
                    notifyAuth(device, denied)
                }
            }
            0x02 -> {
                val code = pairingCode
                val valid = code != null && SystemClock.elapsedRealtime() < pairingExpiresAt
                if (code != null && valid) {
                    val codeKey = Crypto.sha256(code.toByteArray(Charsets.UTF_8))
                    if (Crypto.constantTimeEquals(proof, Crypto.hmac16(codeKey, nonce))) {
                        // Code correct : on crée la clé, et on la renvoie chiffrée avec le code
                        val ltk = Crypto.randomBytes(16)
                        saveLtk(ltk)
                        val stream = Crypto.hmac16(codeKey, nonce + "enc".toByteArray(Charsets.UTF_8))
                        authorized.add(device)
                        authNonces.remove(device)
                        endPairing()
                        notifyAuth(device, byteArrayOf(AUTH_PAIRED.toByte()) + Crypto.xor(ltk, stream))
                        status("iPhone lié")
                        applyMirror(device)
                        return
                    }
                    pairingAttempts++
                    if (pairingAttempts >= PAIRING_MAX_ATTEMPTS) endPairing()
                }
                notifyAuth(device, denied)
            }
            else -> notifyAuth(device, denied)
        }
    }

    // --- Heures calmes, filtre par app, rappel de bouger ------------------------------

    /** Un bit par app, dans le même ordre que la liste de l'app iPhone. */
    private val appMatchers: List<List<String>> = listOf(
        listOf("mobilesms"), listOf("mobilephone"), listOf("mobilemail"), listOf("whatsapp"),
        listOf("instagram"), listOf("snapchat"), listOf("telegram", "telegraph"),
        listOf("facebook.orca", "messenger"), listOf("discord"), listOf("musically", "tiktok"),
        listOf("gmail"), listOf("skype", "teams")
    )

    private fun appAllowed(appId: String): Boolean {
        val mask = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_APP_MASK, 0xFFFF)
        val id = appId.lowercase()
        val index = appMatchers.indexOfFirst { group -> group.any { id.contains(it) } }
        val bit = if (index >= 0) index else 15
        return ((mask shr bit) and 1) == 1
    }

    private fun isQuiet(): Boolean {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_QUIET_ON, false)) return false
        val start = prefs.getInt(KEY_QUIET_START, 22)
        val end = prefs.getInt(KEY_QUIET_END, 7)
        val hour = LocalTime.now().hour
        return if (start <= end) hour in start until end else (hour >= start || hour < end)
    }

    private val moveRunnable: Runnable = object : Runnable {
        override fun run() {
            val minutes = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_MOVE_MIN, 0)
            val now = SystemClock.elapsedRealtime()
            val hour = LocalTime.now().hour
            if (minutes > 0 && onBody && !isQuiet() && hour in 8..21 && now - lastMoveAt >= minutes * 60_000L) {
                lastMoveAt = now
                remindToMove()
            }
            handler.postDelayed(this, 60_000)
        }
    }

    private fun remindToMove() {
        vibrate(longArrayOf(0, 300, 200, 300), -1)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("move", "Rappel de bouger", NotificationManager.IMPORTANCE_HIGH)
        )
        nm.notify(
            2,
            Notification.Builder(this, "move")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Bouge un peu")
                .setContentText("Tu n'as pas marché depuis un moment.")
                .setAutoCancel(true)
                .build()
        )
    }

    // --- Notifications de l'iPhone affichées sur la montre (ANCS) ---------------------

    private fun applyMirror(device: BluetoothDevice) {
        val enabled = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_MIRROR, false)
        if (!enabled) {
            ancs?.stop()
            return
        }
        try {
            val client = ancs ?: AncsClient(this, { text -> status(text) }, { id -> appAllowed(id) }, { isQuiet() }).also { ancs = it }
            client.start(device)
        } catch (e: Exception) {
            Log.w(TAG, "ANCS: $e")
            status("Notifications iPhone : erreur")
        }
    }

    // --- Synchronisation du journal -----------------------------------------------

    private fun le32(v: Long): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v shr 8) and 0xFF).toByte(),
        ((v shr 16) and 0xFF).toByte(),
        ((v shr 24) and 0xFF).toByte()
    )

    private fun syncActive(): Boolean = syncDevice != null && !syncQueue.isEmpty()

    /** Découpe les enregistrements en paquets qui tiennent dans une notification. */
    private fun enqueueBatches(type: Int, records: List<ByteArray>, recordSize: Int) {
        val capacity = (currentMtu - 3 - 1).coerceIn(recordSize, 200)
        val perPacket = (capacity / recordSize).coerceAtLeast(1)
        var i = 0
        while (i < records.size) {
            val chunk = records.subList(i, minOf(i + perPacket, records.size))
            val out = ByteArray(1 + chunk.size * recordSize)
            out[0] = type.toByte()
            var pos = 1
            for (record in chunk) {
                System.arraycopy(record, 0, out, pos, recordSize)
                pos += recordSize
            }
            syncQueue.addLast(out)
            i += perPacket
        }
    }

    /** L'iPhone demande tout ce qui est plus récent que `since` (secondes). */
    private fun startSync(device: BluetoothDevice, since: Long) {
        syncQueue.clear()
        syncInFlight = false
        syncDevice = device
        val snapshot = sampleLog.readSince(since)
        enqueueBatches(
            SYNC_HEART_RATE,
            snapshot.heartRate.map { le32(it.first) + byteArrayOf(it.second.coerceIn(0, 255).toByte()) },
            5
        )
        enqueueBatches(
            SYNC_BATTERY,
            snapshot.battery.map { le32(it.first) + byteArrayOf(it.second.coerceIn(0, 100).toByte()) },
            5
        )
        enqueueBatches(
            SYNC_STEPS,
            snapshot.steps.map { le32(it.first) + le32(it.second.toLong()) },
            8
        )
        syncQueue.addLast(byteArrayOf(SYNC_END.toByte()))
        pumpSync()
    }

    /** Une seule notification à la fois : on attend onNotificationSent avant la suivante. */
    private fun pumpSync() {
        val device = syncDevice ?: return
        val characteristic = syncCharacteristic ?: return
        if (syncInFlight) return
        val packet = syncQueue.pollFirst() ?: return
        try {
            val result: Int? = gattServer?.notifyCharacteristicChanged(device, characteristic, false, packet)
            if (result == BluetoothStatusCodes.SUCCESS) {
                syncInFlight = true
            } else {
                // Occupé (une autre notification part) : on remet le paquet en tête et on réessaie
                syncQueue.addFirst(packet)
                handler.postDelayed({ pumpSync() }, 50)
            }
        } catch (e: SecurityException) {
            syncQueue.clear()
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

            val event = BluetoothGattCharacteristic(
                CTRL_EVENT,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                0
            )
            event.addDescriptor(cccd())
            controlService.addCharacteristic(event)
            eventCharacteristic = event

            val sync = BluetoothGattCharacteristic(
                CTRL_SYNC,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                0
            )
            sync.addDescriptor(cccd())
            controlService.addCharacteristic(sync)
            syncCharacteristic = sync

            val auth = BluetoothGattCharacteristic(
                CTRL_AUTH,
                BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            auth.addDescriptor(cccd())
            controlService.addCharacteristic(auth)
            authCharacteristic = auth

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

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            currentMtu = mtu
        }

        override fun onNotificationSent(device: BluetoothDevice, gattStatus: Int) {
            handler.post {
                syncInFlight = false
                pumpSync()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, gattStatus: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                hrSubscribers.remove(device)
                batterySubscribers.remove(device)
                eventSubscribers.remove(device)
                authorized.remove(device)
                authNonces.remove(device)
                ancs?.stop()
                if (syncDevice == device) {
                    syncDevice = null
                    syncQueue.clear()
                    syncInFlight = false
                }
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
                val characteristicUuid = descriptor.characteristic.uuid
                // Seule la liaison est ouverte à tous : le reste exige un iPhone lié
                if (enabled && characteristicUuid != CTRL_AUTH && !authorized.contains(device)) {
                    if (responseNeeded) {
                        respond(device, requestId, BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION, null)
                    }
                    return
                }
                when (characteristicUuid) {
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
                    CTRL_EVENT -> {
                        if (enabled) {
                            eventSubscribers.add(device)
                            handler.post {
                                notifySteps()
                                notifyWorn()
                            }
                        } else {
                            eventSubscribers.remove(device)
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
                CTRL_EVENT -> eventSubscribers.contains(device)
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
            when (characteristic.uuid) {
                BATTERY_LEVEL -> {
                    if (authorized.contains(device)) {
                        respond(device, requestId, BluetoothGatt.GATT_SUCCESS, byteArrayOf(batteryPercent().toByte()))
                    } else {
                        respond(device, requestId, BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION, null)
                    }
                }
                CTRL_AUTH -> {
                    // Un défi aléatoire à chaque lecture : l'iPhone doit le signer pour prouver qu'il connaît la clé ou le code
                    val nonce = Crypto.randomBytes(16)
                    authNonces[device] = nonce
                    val header = if (loadLtk() != null) AUTH_READ_PAIRED else AUTH_READ_UNPAIRED
                    respond(device, requestId, BluetoothGatt.GATT_SUCCESS, byteArrayOf(header.toByte()) + nonce)
                }
                else -> respond(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, null)
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
            when (characteristic.uuid) {
                CTRL_AUTH -> {
                    handler.post { handleAuth(device, value) }
                    if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, value)
                }
                CTRL_COMMAND -> {
                    if (authorized.contains(device)) {
                        handler.post { handleCommand(device, value) }
                        if (responseNeeded) respond(device, requestId, BluetoothGatt.GATT_SUCCESS, value)
                    } else if (responseNeeded) {
                        respond(device, requestId, BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION, null)
                    }
                }
                else -> if (responseNeeded) {
                    respond(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, null)
                }
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

    /** Commandes envoyées par un iPhone lié. */
    private fun handleCommand(device: BluetoothDevice, value: ByteArray) {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        when (value.firstOrNull()?.toInt()) {
            CMD_RING_START -> startRing()
            CMD_VIBRATE_START -> startVibrateOnly()
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
            CMD_SET_INTERVAL -> if (value.size >= 3) {
                val seconds = ((value[1].toInt() and 0xFF) shl 8) or (value[2].toInt() and 0xFF)
                if (seconds != prefs.getInt(KEY_HR_INTERVAL, 1)) {
                    prefs.edit().putInt(KEY_HR_INTERVAL, seconds).apply()
                    applyInterval()
                }
            }
            CMD_SET_MIRROR -> if (value.size >= 2) {
                prefs.edit().putBoolean(KEY_MIRROR, value[1].toInt() != 0).apply()
                applyMirror(device)
            }
            CMD_SET_MOVE -> if (value.size >= 3) {
                val minutes = ((value[1].toInt() and 0xFF) shl 8) or (value[2].toInt() and 0xFF)
                prefs.edit().putInt(KEY_MOVE_MIN, minutes).apply()
                lastMoveAt = SystemClock.elapsedRealtime()
            }
            CMD_SET_APPS -> if (value.size >= 3) {
                val mask = ((value[1].toInt() and 0xFF) shl 8) or (value[2].toInt() and 0xFF)
                prefs.edit().putInt(KEY_APP_MASK, mask).apply()
            }
            CMD_SET_QUIET -> if (value.size >= 4) {
                prefs.edit()
                    .putBoolean(KEY_QUIET_ON, value[1].toInt() != 0)
                    .putInt(KEY_QUIET_START, value[2].toInt() and 0xFF)
                    .putInt(KEY_QUIET_END, value[3].toInt() and 0xFF)
                    .apply()
            }
            CMD_SYNC_REQUEST -> if (value.size >= 5) {
                var since = 0L
                for (k in 0 until 4) {
                    since = since or ((value[1 + k].toLong() and 0xFF) shl (8 * k))
                }
                startSync(device, since)
            }
        }
    }

    private fun notifyHeartRate(bpm: Int) {
        val characteristic = hrCharacteristic ?: return
        if (syncActive()) return
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

    /** Envoie un événement à tous les iPhone liés et abonnés. */
    private fun sendEvent(payload: ByteArray) {
        val characteristic = eventCharacteristic ?: return
        if (syncActive()) return
        for (device in eventSubscribers) {
            try {
                gattServer?.notifyCharacteristicChanged(device, characteristic, false, payload)
            } catch (e: SecurityException) {
                Log.w(TAG, "notify événement: $e")
            }
        }
    }

    private fun status(text: String) {
        onStatus?.invoke(text)
    }
}
