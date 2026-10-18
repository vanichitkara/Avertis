package com.avertis.avertis

import android.annotation.SuppressLint
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
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

/**
 * The peripheral half of the Avertis BLE mesh.
 *
 * flutter_blue_plus only implements the central role — it can scan and
 * connect, but it cannot advertise or host a GATT server. A mesh needs every
 * node to be *both*: if nobody advertises, nobody is ever discovered, and the
 * central half has nothing to connect to. This class supplies the missing
 * half, exactly as the project plan anticipated (§13).
 *
 * Responsibilities:
 *  - advertise the Avertis service so peers can find this node
 *  - host a GATT server with one write characteristic (peers → us) and one
 *    notify characteristic (us → peers)
 *  - reassemble the fragmented frames defined in docs/protocol.md §7
 *
 * It deliberately knows nothing about packets, routing or priorities. It moves
 * bytes; the Dart mesh engine decides what they mean.
 */
class AvertisBlePeripheral(
    private val context: Context,
    private val listener: Listener,
) {
    interface Listener {
        /** A complete reassembled payload arrived from [deviceId]. */
        fun onPayload(deviceId: String, bytes: ByteArray)

        /** A peer connected or disconnected at the link layer. */
        fun onPeerConnected(deviceId: String)
        fun onPeerDisconnected(deviceId: String)

        /** Advertising started or failed, so Dart can surface the real state. */
        fun onAdvertisingStateChanged(advertising: Boolean, error: String?)
    }

    companion object {
        private const val TAG = "AvertisBle"

        // Must match mobile/lib/mesh/transport/ble_mesh_transport.dart and
        // docs/protocol.md §7.
        val SERVICE_UUID: UUID =
            UUID.fromString("a5e7f1c0-1c2b-4c9a-9f10-000000000001")
        val TX_CHARACTERISTIC_UUID: UUID =
            UUID.fromString("a5e7f1c0-1c2b-4c9a-9f10-000000000002")
        val NOTIFY_CHARACTERISTIC_UUID: UUID =
            UUID.fromString("a5e7f1c0-1c2b-4c9a-9f10-000000000003")
        private val CCC_DESCRIPTOR_UUID: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Conservative payload per notification. docs/protocol.md §7. */
        private const val SAFE_FRAGMENT_BYTES = 180

        /** How long to wait for onNotificationSent before giving up. */
        private const val NOTIFY_TIMEOUT_MS = 5_000L
        private const val REASSEMBLY_TIMEOUT_MS = 10_000L
    }

    private val bluetoothManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null

    private val connected = mutableMapOf<String, BluetoothDevice>()
    private val subscribed = mutableSetOf<String>()
    private val buffers = mutableMapOf<String, Reassembly>()
    private val handler = Handler(Looper.getMainLooper())

    /**
     * Frames waiting to be notified, and the one currently in flight.
     *
     * Android allows a single outstanding notification per connection:
     * the next notifyCharacteristicChanged must wait for
     * onNotificationSent. This sent every fragment of a packet in a tight
     * loop instead, so for a three-fragment packet the first went out and
     * the other two were refused — the peer received an opening fragment
     * and nothing to complete it, for every packet sent this way.
     *
     * Reports are three fragments. Beacons are three. Acknowledgements
     * are two. So nothing larger than a single fragment ever crossed this
     * direction of the link, which is the whole of it in the case where
     * the peer connected to us.
     */
    private class Outgoing(
        val deviceId: String,
        val frames: ArrayDeque<ByteArray>,
        val onDone: (Boolean) -> Unit,
    )

    private val outbox = ArrayDeque<Outgoing>()
    private var inFlight: Outgoing? = null
    private var inFlightTimeout: Runnable? = null

    /**
     * Identifies the frame currently in flight.
     *
     * A confirmation that arrives after its own timeout has already
     * fired would otherwise complete whichever frame started next,
     * marking a packet sent that was never sent and skipping a fragment.
     */
    private var inFlightToken = 0L
    private var nextToken = 1L

    var nodeId: String = ""
        private set
    var isAdvertising: Boolean = false
        private set

    /** One peer's in-flight fragment reassembly. */
    private class Reassembly {
        val fragments = mutableMapOf<Int, ByteArray>()
        var expected = 0
        var totalBytes = 0
        var lastFragmentAt = System.currentTimeMillis()

        fun touch() {
            val now = System.currentTimeMillis()
            if (now - lastFragmentAt > REASSEMBLY_TIMEOUT_MS) reset()
            lastFragmentAt = now
        }

        fun reset() {
            fragments.clear()
            expected = 0
            totalBytes = 0
        }
    }

    // -- lifecycle --------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun start(nodeId: String, role: String, battery: Double): Boolean {
        this.nodeId = nodeId
        val manager = bluetoothManager ?: run {
            listener.onAdvertisingStateChanged(false, "NO_BLUETOOTH_MANAGER")
            return false
        }
        val adapter = manager.adapter ?: run {
            listener.onAdvertisingStateChanged(false, "NO_ADAPTER")
            return false
        }
        if (!adapter.isEnabled) {
            listener.onAdvertisingStateChanged(false, "BLUETOOTH_OFF")
            return false
        }
        if (!adapter.isMultipleAdvertisementSupported) {
            // Some older handsets cannot advertise at all. The node can still
            // act as a central and reach peers that can advertise, so this is
            // reported rather than treated as fatal.
            listener.onAdvertisingStateChanged(false, "ADVERTISING_UNSUPPORTED")
        }

        if (!openGattServer(manager)) return false
        return startAdvertising(adapter.bluetoothLeAdvertiser, role, battery)
    }

    @SuppressLint("MissingPermission")
    private fun openGattServer(manager: BluetoothManager): Boolean {
        val server = manager.openGattServer(context, gattServerCallback) ?: run {
            listener.onAdvertisingStateChanged(false, "GATT_SERVER_FAILED")
            return false
        }
        gattServer = server

        val service = BluetoothGattService(
            SERVICE_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        )

        // Peers write frames to us here.
        val write = BluetoothGattCharacteristic(
            TX_CHARACTERISTIC_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )

        // We push frames to peers here.
        val notify = BluetoothGattCharacteristic(
            NOTIFY_CHARACTERISTIC_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        notify.addDescriptor(
            BluetoothGattDescriptor(
                CCC_DESCRIPTOR_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE,
            )
        )
        notifyCharacteristic = notify

        service.addCharacteristic(write)
        service.addCharacteristic(notify)
        server.addService(service)
        return true
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(
        bleAdvertiser: BluetoothLeAdvertiser?,
        role: String,
        battery: Double,
    ): Boolean {
        val adv = bleAdvertiser ?: run {
            listener.onAdvertisingStateChanged(false, "NO_ADVERTISER")
            return false
        }
        advertiser = adv

        val settings = AdvertiseSettings.Builder()
            // A disaster node may need to last days, but it is also useless if
            // it is never discovered. BALANCED is the compromise; the mesh
            // engine's own duty cycling does the rest of the power saving.
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        // A legacy BLE advertisement is 31 bytes, total, and it is easy to
        // exceed without noticing: the radio simply refuses to start with
        // DATA_TOO_LARGE and the node is never discovered.
        //
        //   flags                       3 bytes  (added automatically)
        //   128-bit service UUID   2 + 16 bytes
        //                              = 21 bytes
        //
        // That leaves 10, which is not enough for manufacturer data (4 bytes
        // of overhead plus our 8-byte payload = 12). So the UUID travels in
        // the advertisement, where it is needed for filtered scanning, and
        // everything else moves to the scan response — a second 31-byte
        // budget that an active scan collects at the same time.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        // Enough for a peer to score us before paying the cost of connecting
        // (docs/protocol.md §7): 6-byte node id, 1-byte role, 1-byte battery.
        // 12 bytes with overhead, comfortably inside the scan response.
        val payload = ByteArray(8)
        val idBytes = nodeId.padEnd(6, ' ').substring(0, 6).toByteArray()
        idBytes.copyInto(payload, 0, 0, 6)
        payload[6] = roleCode(role)
        payload[7] = (battery.coerceIn(0.0, 1.0) * 255).toInt().toByte()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(MANUFACTURER_ID, payload)
            .build()

        adv.startAdvertising(settings, data, scanResponse, advertiseCallback)
        return true
    }

    private fun roleCode(role: String): Byte = when (role) {
        "SURVIVOR" -> 0
        "RESPONDER" -> 1
        "RELAY" -> 2
        "GATEWAY" -> 3
        else -> 0
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (e: Exception) {
            Log.w(TAG, "stopAdvertising failed", e)
        }
        isAdvertising = false
        try {
            gattServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "gatt close failed", e)
        }
        gattServer = null
        advertiser = null
        connected.clear()
        subscribed.clear()
        buffers.clear()
    }

    // -- sending ----------------------------------------------------------

    /**
     * Push a payload to one connected peer, fragmenting per docs/protocol.md §7.
     * Returns false if the peer is not connected or has not subscribed.
     */
    @SuppressLint("MissingPermission")
    fun send(deviceId: String, bytes: ByteArray, onDone: (Boolean) -> Unit) {
        if (gattServer == null || notifyCharacteristic == null) {
            onDone(false)
            return
        }
        if (connected[deviceId] == null || deviceId !in subscribed) {
            onDone(false)
            return
        }

        handler.post {
            outbox.addLast(
                Outgoing(deviceId, ArrayDeque(fragment(bytes)), onDone)
            )
            pumpOutbox()
        }
    }

    /** Send one frame and wait for the stack to say it went. */
    @SuppressLint("MissingPermission")
    private fun pumpOutbox() {
        if (inFlight != null) return
        val next = outbox.removeFirstOrNull() ?: return

        val server = gattServer
        val characteristic = notifyCharacteristic
        val device = connected[next.deviceId]
        if (server == null || characteristic == null || device == null ||
            next.deviceId !in subscribed
        ) {
            next.onDone(false)
            handler.post { pumpOutbox() }
            return
        }

        inFlight = next
        val token = nextToken++
        inFlightToken = token
        val frame = next.frames.removeFirst()
        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(
                device, characteristic, false, frame
            ) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = frame
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(device, characteristic, false)
        }

        if (!ok) {
            finishInFlight(token, false)
            return
        }

        // A callback that never arrives must not wedge the queue for good.
        val timeout = Runnable {
            Log.w(TAG, "notification to ${next.deviceId} was never confirmed")
            finishInFlight(token, false)
        }
        inFlightTimeout = timeout
        handler.postDelayed(timeout, NOTIFY_TIMEOUT_MS)
    }

    /** The frame in flight has landed, failed, or timed out. */
    private fun finishInFlight(token: Long, sent: Boolean) {
        // Stale confirmation for a frame already given up on.
        if (token != inFlightToken) return
        inFlightTimeout?.let { handler.removeCallbacks(it) }
        inFlightTimeout = null
        inFlightToken = 0

        val current = inFlight ?: return
        if (!sent) {
            // One lost fragment makes the whole packet unassemblable, so
            // the rest of it is not worth the radio time.
            inFlight = null
            current.onDone(false)
        } else if (current.frames.isEmpty()) {
            inFlight = null
            current.onDone(true)
        } else {
            inFlight = null
            outbox.addFirst(current)
        }
        pumpOutbox()
    }

    fun connectedPeers(): List<String> = connected.keys.sorted()

    /** Fragment framing: [2-byte total][1-byte index][1-byte count][chunk]. */
    private fun fragment(payload: ByteArray): List<ByteArray> {
        val chunkSize = SAFE_FRAGMENT_BYTES - 4
        val count = maxOf(1, (payload.size + chunkSize - 1) / chunkSize)
        require(count <= 255) { "payload too large to fragment: ${payload.size}" }

        return (0 until count).map { i ->
            val start = i * chunkSize
            val end = minOf(start + chunkSize, payload.size)
            val chunk = payload.copyOfRange(start, end)
            ByteArray(4 + chunk.size).also { frame ->
                frame[0] = (payload.size shr 8).toByte()
                frame[1] = (payload.size and 0xFF).toByte()
                frame[2] = i.toByte()
                frame[3] = count.toByte()
                chunk.copyInto(frame, 4)
            }
        }
    }

    /** Feed one frame; emit the payload once every fragment has arrived. */
    private fun accept(deviceId: String, frame: ByteArray) {
        if (frame.size < 4) return
        val total = ((frame[0].toInt() and 0xFF) shl 8) or (frame[1].toInt() and 0xFF)
        val index = frame[2].toInt() and 0xFF
        val count = frame[3].toInt() and 0xFF
        if (count == 0 || index >= count) return

        val buffer = buffers.getOrPut(deviceId) { Reassembly() }
        buffer.touch()
        buffer.expected = count
        buffer.totalBytes = total
        buffer.fragments[index] = frame.copyOfRange(4, frame.size)

        if (buffer.fragments.size != count) return

        val assembled = ByteArray(total)
        var offset = 0
        for (i in 0 until count) {
            val part = buffer.fragments[i] ?: return
            if (offset + part.size > total) { buffer.reset(); return }
            part.copyInto(assembled, offset)
            offset += part.size
        }
        buffer.reset()
        if (offset != total) return
        listener.onPayload(deviceId, assembled)
    }

    // -- callbacks --------------------------------------------------------

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            listener.onAdvertisingStateChanged(true, null)
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
                ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
                else -> "UNKNOWN_$errorCode"
            }
            Log.w(TAG, "advertising failed: $reason")
            listener.onAdvertisingStateChanged(false, reason)
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: BluetoothDevice,
            status: Int,
            newState: Int,
        ) {
            val id = device.address
            handler.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    connected[id] = device
                    listener.onPeerConnected(id)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    connected.remove(id)
                    subscribed.remove(id)
                    buffers.remove(id)
                    listener.onPeerDisconnected(id)
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid == TX_CHARACTERISTIC_UUID) {
                handler.post { accept(device.address, value) }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null
                )
            }
        }

        @SuppressLint("MissingPermission")
        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val token = inFlightToken
            handler.post {
                finishInFlight(token, status == BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (descriptor.uuid == CCC_DESCRIPTOR_UUID) {
                val enabling = value.contentEquals(
                    BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                )
                handler.post {
                    if (enabling) subscribed.add(device.address)
                    else subscribed.remove(device.address)
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null
                )
            }
        }
    }
}

/** Arbitrary company id for the demo. Not a registered Bluetooth SIG id. */
private const val MANUFACTURER_ID = 0xFFFE
