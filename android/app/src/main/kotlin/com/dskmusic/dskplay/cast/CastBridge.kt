package com.dskmusic.dskplay.cast

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Puente Flutter <-> [CastController]. Solo traduce llamadas: la logica de
 * reproduccion remota y los heuristicos de fin de pista viven en el controller.
 *
 * El canal es bidireccional: Dart llama a load/play/pause/..., y Kotlin devuelve
 * por el mismo canal onPosition / onTrackFinished / onDisconnected.
 */
class CastBridge private constructor(context: Context) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())
    private val controller = CastController(context.applicationContext)
    private var channel: MethodChannel? = null

    companion object {
        const val CHANNEL = "com.dskmusic.dskplay/cast"

        // audio_service recrea el FlutterEngine y registerChannels() se vuelve a
        // llamar con otro messenger: un unico controller por proceso (si no, se
        // perderia la sesion con la tele al recrearse el motor), solo se
        // recoloca el canal.
        @Volatile
        private var instance: CastBridge? = null

        fun register(messenger: BinaryMessenger, context: Context) {
            val bridge = instance ?: synchronized(this) {
                instance ?: CastBridge(context).also { instance = it }
            }
            val channel = MethodChannel(messenger, CHANNEL)
            channel.setMethodCallHandler(bridge)
            bridge.attach(channel)
        }
    }

    private fun attach(newChannel: MethodChannel) {
        channel = newChannel
        CastLog.sink = { msg -> main.post { channel?.invokeMethod("onLog", msg) } }
        controller.onPosition = { pos, dur, playing ->
            main.post {
                channel?.invokeMethod(
                    "onPosition",
                    mapOf("position" to pos, "duration" to dur, "playing" to playing),
                )
            }
        }
        controller.onTrackFinished = {
            main.post { channel?.invokeMethod("onTrackFinished", null) }
        }
        controller.onDisconnected = {
            main.post { channel?.invokeMethod("onDisconnected", null) }
        }
    }

    private fun deviceMap(device: KastDevice): Map<String, Any?> = mapOf(
        "id" to controller.keyOf(device),
        "name" to device.name,
        "type" to device.type,
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(controller.isAvailable())

            "startDiscovery" -> {
                controller.startDiscovery()
                result.success(null)
            }

            "stopDiscovery" -> {
                controller.stopDiscovery()
                result.success(null)
            }

            // Los receptores se entregan de uno en uno segun aparecen (SSDP
            // tarda varios segundos): la lista de la UI se va rellenando sola.
            "discover" -> {
                controller.discover(
                    { device -> channel?.invokeMethod("onDevice", deviceMap(device)) },
                    { channel?.invokeMethod("onDiscoveryFinished", null) },
                )
                result.success(null)
            }

            "load" -> controller.load(
                deviceKey = call.argument<String>("deviceId")!!,
                url = call.argument<String>("url"),
                localPath = call.argument<String>("localPath"),
                title = call.argument<String>("title") ?: "",
                artist = call.argument<String>("artist") ?: "",
                artworkUrl = call.argument<String>("artwork"),
                isLive = call.argument<Boolean>("isLive") ?: false,
                startSeconds = call.argument<Int>("startSeconds") ?: 0,
                durationMs = (call.argument<Int>("durationMs") ?: 0).toLong(),
            ) { ok, msg ->
                if (ok) result.success(msg) else result.error("cast", msg, null)
            }

            "play" -> { controller.play(); result.success(null) }
            "pause" -> { controller.pause(); result.success(null) }
            "stop" -> { controller.stop(); result.success(null) }
            "seek" -> {
                controller.seek(call.argument<Int>("seconds") ?: 0)
                result.success(null)
            }
            "disconnect" -> { controller.disconnect(); result.success(null) }

            else -> result.notImplemented()
        }
    }
}
