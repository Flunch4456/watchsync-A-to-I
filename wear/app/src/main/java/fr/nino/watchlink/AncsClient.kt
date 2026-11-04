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
        private const val CHANNEL = "iphone_notifications_v2"
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

    /** Demande l'app (0), le titre (1), le sous-titre (2, souvent l'objet) et le message (3). */
    private fun requestAttributes(uid: Long) {
        val b = byteArrayOf(
            0x00,
            (uid and 0xFF).toByte(), ((uid shr 8) and 0xFF).toByte(),
            ((uid shr 16) and 0xFF).toByte(), ((uid shr 24) and 0xFF).toByte(),
            0x00,
            0x01, 100, 0,
            0x02, 100, 0,
            0x03, 0xF4.toByte(), 0x01 // 500 caractères
        )
        requests.addLast(b)
        pump()
    }

    /** Demande le vrai nom d'une app (« WhatsApp ») à partir de son identifiant (« net.whatsapp.WhatsApp »). */
    private fun requestAppName(appId: String) {
        requests.addLast(byteArrayOf(0x01) + appId.toByteArray(Charsets.UTF_8) + byteArrayOf(0x00, 0x00))
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

    private val appNames = HashMap<String, String>()
    private class Pending(val uid: Long, val title: String, val subtitle: String, val message: String)
    private val waiting = HashMap<String, MutableList<Pending>>()

    /**
     * Deux types de réponses arrivent dans le même flux :
     *  - 0 : notification = UID (4 octets), puis (id, longueur sur 2 octets, valeur) pour app, titre, sous-titre, message
     *  - 1 : app = identifiant terminé par un octet nul, puis (id, longueur, valeur) pour le nom affiché
     */
    private fun parseData() {
        while (true) {
            val b = buffer.toByteArray()
            if (b.isEmpty()) return
            var i: Int
            val consumed: Int
            when (b[0].toInt()) {
                0 -> {
                    if (b.size < 5) return
                    i = 5
                    val attrs = HashMap<Int, String>()
                    for (n in 0 until 4) {
                        if (i + 3 > b.size) return
                        val id = b[i].toInt() and 0xFF
                        val len = (b[i + 1].toInt() and 0xFF) or ((b[i + 2].toInt() and 0xFF) shl 8)
                        if (i + 3 + len > b.size) return
                        attrs[id] = String(b, i + 3, len, Charsets.UTF_8)
                        i += 3 + len
                    }
                    consumed = i
                    onNotification(le32(b, 1), attrs[0] ?: "", attrs[1] ?: "", attrs[2] ?: "", attrs[3] ?: "")
                }
                1 -> {
                    var end = 1
                    while (end < b.size && b[end].toInt() != 0) end++
                    if (end >= b.size) return
                    val appId = String(b, 1, end - 1, Charsets.UTF_8)
                    i = end + 1
                    if (i + 3 > b.size) return
                    val len = (b[i + 1].toInt() and 0xFF) or ((b[i + 2].toInt() and 0xFF) shl 8)
                    if (i + 3 + len > b.size) return
                    val name = String(b, i + 3, len, Charsets.UTF_8)
                    i += 3 + len
                    consumed = i
                    onAppName(appId, name)
                }
                else -> {
                    buffer.reset()
                    return
                }
            }
            val rest = b.copyOfRange(consumed, b.size)
            buffer.reset()
            buffer.write(rest)
        }
    }

    private fun onNotification(uid: Long, appId: String, title: String, subtitle: String, message: String) {
        val known = appNames[appId]
        if (known != null || appId.isEmpty()) {
            post(uid, known ?: "iPhone", title, subtitle, message)
            return
        }
        // Nom de l'app inconnu : on le demande, et on affiche quand il arrive (ou après 3 s au pire)
        val list = waiting.getOrPut(appId) { mutableListOf() }
        val first = list.isEmpty()
        list.add(Pending(uid, title, subtitle, message))
        if (first) {
            requestAppName(appId)
            handler.postDelayed({
                if (!appNames.containsKey(appId)) onAppName(appId, fallbackName(appId))
            }, 3000)
        }
    }

    private fun onAppName(appId: String, name: String) {
        val shown = name.ifBlank { fallbackName(appId) }
        appNames[appId] = shown
        waiting.remove(appId)?.forEach { post(it.uid, shown, it.title, it.subtitle, it.message) }
    }

    private fun fallbackName(id: String): String = when (id.substringAfterLast('.')) {
        "MobileSMS" -> "Messages"
        "mobilephone" -> "Téléphone"
        "MobileMail" -> "Mail"
        "" -> "iPhone"
        else -> id.substringAfterLast('.')
    }

    private fun notificationId(uid: Long): Int = 20000 + (uid % 100000).toInt()

    /** Titre = expéditeur ou titre ; texte = objet (sous-titre) puis contenu ; sous-texte = nom de l'app. */
    private fun post(uid: Long, app: String, title: String, subtitle: String, message: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Notifications iPhone", NotificationManager.IMPORTANCE_HIGH)
        )
        val body = listOf(subtitle, message).filter { it.isNotBlank() }.joinToString("\n")
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title.ifBlank { app })
            .setContentText(body.lineSequence().firstOrNull() ?: "")
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSubText(app)
            .setShowWhen(true)
            .setAutoCancel(true)
            .build()
        nm.notify(notificationId(uid), notification)
    }
}
