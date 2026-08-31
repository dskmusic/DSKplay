package com.dskmusic.dskplay.cast

import android.util.Log

/**
 * Traza de cast que ademas de a logcat sale por el canal hasta el logger de la
 * app, que es lo que copia Ajustes > Copiar logs. Sin esto, diagnosticar un
 * corte con la tele exigiria un adb que no siempre se tiene a mano.
 */
object CastLog {

    @Volatile
    var sink: ((String) -> Unit)? = null

    fun d(tag: String, msg: String) {
        Log.d(tag, msg)
        sink?.invoke("$tag: $msg")
    }

    fun w(tag: String, msg: String) {
        Log.w(tag, msg)
        sink?.invoke("$tag: $msg")
    }
}
