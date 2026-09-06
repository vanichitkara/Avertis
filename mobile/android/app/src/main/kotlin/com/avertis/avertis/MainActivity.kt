package com.avertis.avertis

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper

/**
 * Bridges the Kotlin BLE peripheral to Dart.
 *
 * flutter_blue_plus covers the central role; this covers the peripheral role
 * it cannot do. Together they make a node that can both find peers and be
 * found — which is the minimum for a mesh.
 */
class MainActivity : FlutterActivity(), AvertisBlePeripheral.Listener {

    companion object {
        private const val METHOD_CHANNEL = "avertis/ble_peripheral"
        private const val EVENT_CHANNEL = "avertis/ble_peripheral/events"
        private const val SERVICE_CHANNEL = "avertis/mesh_service"
    }

    private var peripheral: AvertisBlePeripheral? = null
    private var events: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val nodeId = call.argument<String>("nodeId") ?: ""
                    val role = call.argument<String>("role") ?: "SURVIVOR"
                    val battery = call.argument<Double>("battery") ?: 1.0
                    if (nodeId.isEmpty()) {
                        result.error("BAD_ARGS", "nodeId is required", null)
                    } else {
                        val p = peripheral ?: AvertisBlePeripheral(this, this)
                            .also { peripheral = it }
                        result.success(p.start(nodeId, role, battery))
                    }
                }

                "stop" -> {
                    peripheral?.stop()
                    result.success(true)
                }

                "send" -> {
                    val deviceId = call.argument<String>("deviceId")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (deviceId == null || bytes == null) {
                        result.error("BAD_ARGS", "deviceId and bytes required", null)
                    } else {
                        result.success(
                            peripheral?.send(deviceId, bytes) ?: false
                        )
                    }
                }

                "connectedPeers" ->
                    result.success(peripheral?.connectedPeers() ?: emptyList<String>())

                "isAdvertising" ->
                    result.success(peripheral?.isAdvertising ?: false)

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    // Report what actually happened rather than assuming
                    // success: the service is refused without a Bluetooth
                    // runtime permission, and the UI must not claim
                    // background relaying it is not doing.
                    result.success(MeshForegroundService.start(this))
                }

                "update" -> {
                    MeshForegroundService.update(
                        this,
                        call.argument<Int>("neighbors") ?: 0,
                        call.argument<Int>("queued") ?: 0,
                        call.argument<Int>("custody") ?: 0,
                    )
                    result.success(true)
                }

                "stop" -> {
                    MeshForegroundService.stop(this)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
    }

    private fun emit(payload: Map<String, Any?>) {
        handler.post { events?.success(payload) }
    }

    // -- AvertisBlePeripheral.Listener ------------------------------------

    override fun onPayload(deviceId: String, bytes: ByteArray) {
        emit(mapOf("event" to "payload", "deviceId" to deviceId, "bytes" to bytes))
    }

    override fun onPeerConnected(deviceId: String) {
        emit(mapOf("event" to "peerConnected", "deviceId" to deviceId))
    }

    override fun onPeerDisconnected(deviceId: String) {
        emit(mapOf("event" to "peerDisconnected", "deviceId" to deviceId))
    }

    override fun onAdvertisingStateChanged(advertising: Boolean, error: String?) {
        emit(
            mapOf(
                "event" to "advertisingState",
                "advertising" to advertising,
                "error" to error,
            )
        )
    }

    override fun onDestroy() {
        peripheral?.stop()
        peripheral = null
        super.onDestroy()
    }
}
