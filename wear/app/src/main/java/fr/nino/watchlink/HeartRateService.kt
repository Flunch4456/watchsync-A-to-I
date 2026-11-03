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
import android.os.IBinder
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

/**
 * Service au premier plan : lit le capteur cardiaque de la montre et le diffuse
 * en Bluetooth Low Energy via le profil standard "Heart Rate" (0x180D).
 * Android ne laisse tourner un capteur en continu que dans un service au premier plan,
 * d'où la notification permanente.
 */
class HeartRateService : Service(), SensorEventListener {

    companion object {
        private const val TAG = "WatchLink"
        private const val CHANNEL_ID = "watchlink"
        private const val NOTIF_ID = 1

        val HR_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HR_MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        @Volatile var running: Boolean = false
        /** Appelés depuis le service pour mettre à jour l'écran. */
        @Volatile var onBpm: ((Int) -> Unit)? = null
        @Volatile var onStatus: ((String) -> Unit)? = null
    }

    private lateinit var sensorManager: SensorManager
    private var gattServer: BluetoothGattServer? = null
    private var hrCharacteristic: BluetoothGattCharacteristic? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val subscribers = mutableSetOf<BluetoothDevice>()
    private var lastBpm = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        if (!running) {
            running = true
            startSensor()
            startBle()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
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
        subscribers.clear()
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
        notifySubscribers(bpm)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    // --- Serveur Bluetooth (profil Heart Rate) -----------------------------------

    private fun startBle() {
        val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = btManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            status("Bluetooth désactivé")
            return
        }
        try {
            gattServer = btManager.openGattServer(this, gattCallback)

            val service = BluetoothGattService(HR_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val measurement = BluetoothGattCharacteristic(
                HR_MEASUREMENT,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                0
            )
            // Le descripteur CCCD permet au client (l'iPhone) de s'abonner aux notifications
            measurement.addDescriptor(
                BluetoothGattDescriptor(
                    CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
            service.addCharacteristic(measurement)
            hrCharacteristic = measurement
            gattServer?.addService(service)

            advertiser = adapter.bluetoothLeAdvertiser
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
        override fun onConnectionStateChange(device: BluetoothDevice, gattStatus: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribers.remove(device)
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
                if (enabled) {
                    subscribers.add(device)
                    status("iPhone abonné")
                    if (lastBpm > 0) notifySubscribers(lastBpm)
                } else {
                    subscribers.remove(device)
                }
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
                } catch (e: SecurityException) {
                    Log.w(TAG, "sendResponse: $e")
                }
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor
        ) {
            val value = if (subscribers.contains(device))
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            else
                BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            try {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
            } catch (e: SecurityException) {
                Log.w(TAG, "sendResponse: $e")
            }
        }
    }

    private fun notifySubscribers(bpm: Int) {
        val characteristic = hrCharacteristic ?: return
        // Format "Heart Rate Measurement" : octet de flags (0 = valeur sur 8 bits), puis le BPM
        val payload = byteArrayOf(0x00, bpm.coerceIn(0, 255).toByte())
        for (device in subscribers.toList()) {
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
