package fr.nino.watchlink

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Notification
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * Reçoit les notifications de l'iPhone grâce à ANCS (Apple Notification Center Service) et les
 * affiche sur la montre. L'iPhone n'expose ce service qu'à un appareil appairé (bond) auquel
 * l'utilisateur a accordé « Partager les notifications du système » dans Réglages > Bluetooth.
 */
class AncsClient(private val context: Context, private val onStatus: (String) -> Unit) {

    companion object {
        private const val TAG = "WatchLinkAncs"
        private const val CHANNEL = "iphone_notifications"
        private val SERVICE: UUID = UUID.fromString("7905F431-B5CE-4E99-A40F-4B1E122D00D0")
        private val NOTIFICATION_SOURCE: UUID = UUID.fromString("9FBF120D-6301-42D9-8C58-25E699A21DBD")
        private val CONTROL_POINT: UUID = UUID.fromString("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9")
        private val DATA_SOURCE: UUID = UUID.fromString("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val handler = Handler(Looper.getMainLooper())
    private var device: BluetoothDevice? = null
    private var gatt: BluetoothGatt? = null
    private var control: BluetoothGattCharacteristic? = null
    private var dataSource: BluetoothGattCharacteristic? = null
    private val buffer = ByteArrayOutputStream()
    private val requests = ArrayDeque<ByteArray>()
    private var writing = false
    private var receiverRegistered = false

    private val bondReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val d: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            if (d == null || d.address != device?.address) return
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            if (state == BluetoothDevice.BOND_BONDED) {
                onStatus("iPhone appairé, connexion aux notifications…")
                handler.post { connect() }
            } else if (state == BluetoothDevice.BOND_NONE) {
                onStatus("Appairage refusé : accepte-le sur l'iPhone")
            }
        }
    }

    /** Démarre : appairage si besoin, puis connexion au service de notifications de l'iPhone. */
    fun start(target: BluetoothDevice) {
        stop()
        device = target
        try {
            if (target.bondState == BluetoothDevice.BOND_BONDED) {
                connect()
            } else {
                context.registerReceiver(
                    bondReceiver,
                    IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
                    Context.RECEIVER_EXPORTED
                )
                receiverRegistered = true
                onStatus("Accepte l'appairage sur l'iPhone")
                target.createBond()
            }
        } catch (e: SecurityException) {
            onStatus("Permission Bluetooth refusée")
        }
    }

    fun stop() {
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(bondReceiver)
            } catch (e: Exception) {
                Log.w(TAG, "unregister: $e")
            }
            receiverRegistered = false
        }
        try {
            gatt?.close()
        } catch (e: SecurityException) {
            Log.w(TAG, "close: $e")
        }
        gatt = null
        control = null
        dataSource = null
        requests.clear()
        writing = false
        buffer.reset()
        device = null
    }

    private fun connect() {
        val d = device ?: return
        try {
            gatt?.close()
            gatt = d.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            onStatus("Permission Bluetooth refusée")
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            try {
                if (newState == BluetoothProfile.STATE_CONNECTED) g.discoverServices()
            } catch (e: SecurityException) {
                Log.w(TAG, "discover: $e")
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val service = g.getService(SERVICE)
            if (service == null) {
                onStatus("Notifications iPhone indisponibles : active « Partager les notifications du système » dans Réglages > Bluetooth")
                return
            }
            control = service.getCharacteristic(CONTROL_POINT)
            dataSource = service.getCharacteristic(DATA_SOURCE)
            val notificationSource = service.getCharacteristic(NOTIFICATION_SOURCE) ?: return
            // Données d'abord, puis événements : chaque écriture de descripteur attend la précédente
            subscribe(g, dataSource ?: return)
            pendingSubscription = notificationSource
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val next = pendingSubscription
            if (next != null) {
                pendingSubscription = null
                subscribe(g, next)
            } else {
                onStatus("Notifications iPhone actives")
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            handler.post {
                writing = false
                pump()
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            handler.post {
                when (c.uuid) {
                    NOTIFICATION_SOURCE -> onEvent(value)
                    DATA_SOURCE -> {
                        buffer.write(value)
                        parseData()
                    }
                }
            }
        }
    }

    private var pendingSubscription: BluetoothGattCharacteristic? = null

    private fun subscribe(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
        try {
            g.setCharacteristicNotification(c, true)
            val descriptor = c.getDescriptor(CCCD) ?: return
            g.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } catch (e: SecurityException) {
            Log.w(TAG, "subscribe: $e")
        }
    }

    private fun le32(b: ByteArray, i: Int): Long {
        var n = 0L
        for (k in 0 until 4) n = n or ((b[i + k].toLong() and 0xFF) shl (8 * k))
        return n
    }

    /** Événement de la source de notifications : 8 octets (événement, drapeaux, catégorie, nombre, UID). */
    private fun onEvent(v: ByteArray) {
        if (v.size < 8) return
        val event = v[0].toInt()
        val flags = v[1].toInt() and 0xFF
        val uid = le32(v, 4)
        when (event) {
            0 -> {
                // On ignore les notifications silencieuses et celles qui existaient avant la connexion
                if ((flags and 0x01) == 0 && (flags and 0x04) == 0) requestAttributes(uid)
            }
            2 -> context.getSystemService(NotificationManager::class.java).cancel(notificationId(uid))
        }
    }

    /** Demande l'app (0), le titre (1, 64 car. max) et le message (3, 200 car. max). */
    private fun requestAttributes(uid: Long) {
        val b = byteArrayOf(
            0x00,
            (uid and 0xFF).toByte(), ((uid shr 8) and 0xFF).toByte(),
            ((uid shr 16) and 0xFF).toByte(), ((uid shr 24) and 0xFF).toByte(),
            0x00,
            0x01, 64, 0,
            0x03, 200.toByte(), 0
        )
        requests.addLast(b)
        pump()
    }

    private fun pump() {
        if (writing) return
        val g = gatt ?: return
        val c = control ?: return
        val b = requests.removeFirstOrNull() ?: return
        try {
            val r = g.writeCharacteristic(c, b, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            if (r == BluetoothStatusCodes.SUCCESS) {
                writing = true
            } else {
                requests.addFirst(b)
                handler.postDelayed({ pump() }, 100)
            }
        } catch (e: SecurityException) {
            requests.clear()
        }
    }

    /** Réponse : commande (0), UID (4 octets), puis pour chaque attribut : id, longueur (2 octets), valeur. */
    private fun parseData() {
        while (true) {
            val b = buffer.toByteArray()
            if (b.size < 5) return
            if (b[0].toInt() != 0) {
                buffer.reset()
                return
            }
            var i = 5
            val attrs = HashMap<Int, String>()
            var complete = true
            for (n in 0 until 3) {
                if (i + 3 > b.size) { complete = false; break }
                val id = b[i].toInt() and 0xFF
                val len = (b[i + 1].toInt() and 0xFF) or ((b[i + 2].toInt() and 0xFF) shl 8)
                if (i + 3 + len > b.size) { complete = false; break }
                attrs[id] = String(b, i + 3, len, Charsets.UTF_8)
                i += 3 + len
            }
            if (!complete) return
            post(le32(b, 1), attrs[0] ?: "", attrs[1] ?: "", attrs[3] ?: "")
            val rest = b.copyOfRange(i, b.size)
            buffer.reset()
            buffer.write(rest)
        }
    }

    private fun notificationId(uid: Long): Int = 20000 + (uid % 100000).toInt()

    private fun appName(id: String): String = when (id.substringAfterLast('.')) {
        "MobileSMS" -> "Messages"
        "mobilephone" -> "Téléphone"
        "MobileMail" -> "Mail"
        "whatsapp", "WhatsApp" -> "WhatsApp"
        "" -> "iPhone"
        else -> id.substringAfterLast('.')
    }

    private fun post(uid: Long, app: String, title: String, text: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Notifications iPhone", NotificationManager.IMPORTANCE_DEFAULT)
        )
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title.ifBlank { appName(app) })
            .setContentText(text)
            .setSubText(appName(app))
            .setAutoCancel(true)
            .build()
        nm.notify(notificationId(uid), notification)
    }
}
