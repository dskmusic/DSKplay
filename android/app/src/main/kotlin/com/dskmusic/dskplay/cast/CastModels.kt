package com.dskmusic.dskplay.cast

/**
 * Modelo unificado de receptor (Chromecast o Smart TV DLNA). Portado de Kast
 * (KastModels.kt): la UI de Flutter recibe una sola lista y solo distingue por
 * [type] cuando manda una orden.
 */
data class KastDevice(
    val name: String,
    val type: String,           // "dlna" o "cast"
    val dlnaDevice: DlnaDevice? = null,
    val castDevice: CastDevice? = null,
)

/** Chromecast localizado por MediaRouter. */
data class CastDevice(
    val name: String,
    val routeId: String,
)

/**
 * Pista a cargar en el receptor. Agrupa lo que antes en Kast eran tres
 * parametros sueltos (url/titulo/mime) mas lo que necesita un reproductor de
 * musica: interprete, caratula, si es directo y desde que segundo arrancar.
 */
data class CastTrack(
    val url: String,
    val title: String,
    val artist: String,
    val artworkUrl: String?,
    val mimeType: String,
    val isLive: Boolean,
    val startSeconds: Int,
    /** Duracion conocida en ms, o 0. Alimenta el filtro de fin de pista falso. */
    val durationMs: Long,
)
