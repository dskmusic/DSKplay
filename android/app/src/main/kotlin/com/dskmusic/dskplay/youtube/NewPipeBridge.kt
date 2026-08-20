package com.dskmusic.dskplay.youtube

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Puente Flutter <-> [NewPipeExtraction]. Solo hilos y MethodChannel: toda la
 * extraccion vive en NewPipeExtraction, que no depende de Android y por eso se
 * puede probar de verdad en NewPipeSmokeTest.
 */
class NewPipeBridge private constructor() : MethodChannel.MethodCallHandler {

    private val pool = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL = "com.dskmusic.dskplay/newpipe"

        // audio_service recrea el FlutterEngine, asi que registerChannels() se
        // vuelve a llamar con otro messenger: un unico bridge (y un unico pool)
        // por proceso, solo se recoloca el handler.
        private val instance by lazy {
            NewPipeExtraction.init()
            NewPipeBridge()
        }

        fun register(messenger: BinaryMessenger) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler(instance)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        pool.execute {
            try {
                val value: Any? = when (call.method) {
                    "search" -> NewPipeExtraction.search(
                        call.argument<String>("query")!!,
                        call.argument<List<String>>("filters") ?: listOf("videos"),
                        call.argument<Int>("pages") ?: 1,
                    )
                    "suggestions" -> NewPipeExtraction.suggestions(call.argument<String>("query")!!)
                    "video" -> NewPipeExtraction.video(call.argument<String>("id")!!)
                    "related" -> NewPipeExtraction.related(call.argument<String>("id")!!)
                    "streams" -> NewPipeExtraction.streams(call.argument<String>("id")!!)
                    "playlist" -> NewPipeExtraction.playlist(call.argument<String>("id")!!)
                    "playlistItems" -> NewPipeExtraction.playlistItems(
                        call.argument<String>("id")!!,
                        call.argument<Int>("limit") ?: 500,
                    )
                    "channel" -> NewPipeExtraction.channel(call.argument<String>("id")!!)
                    "channelTab" -> NewPipeExtraction.channelTab(
                        call.argument<String>("id")!!,
                        call.argument<String>("tab")!!,
                        call.argument<Int>("limit") ?: 200,
                    )
                    // Unit no lo sabe codificar el MethodChannel: hay que
                    // devolver null explicitamente.
                    "setProxy" -> {
                        NewPipeExtraction.setProxy(call.argument<String>("proxy"))
                        null
                    }
                    else -> {
                        main.post { result.notImplemented() }
                        return@execute
                    }
                }
                main.post { result.success(value) }
            } catch (e: Throwable) {
                val msg = e.javaClass.simpleName + ": " + (e.message ?: "")
                main.post { result.error("newpipe", msg.take(200), null) }
            }
        }
    }
}
