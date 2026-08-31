package com.dskmusic.dskplay.cast

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Orquestador de la reproduccion remota: descubrimiento, envio, controles y —
 * lo importante — deteccion de fin de pista.
 *
 * Es el port de la logica que en Kast vivia repartida por MainActivity
 * (pollingRunnable, handlePositionUpdate, checkAutoPlayStall, advanceAfterEnd,
 * onRendererEvent). Se queda en Kotlin y no en Dart a proposito: son
 * heuristicas afinadas contra teles reales, y ademas tienen que seguir
 * corriendo con la pantalla apagada.
 */
class CastController(private val context: Context) {

    companion object {
        private const val TAG = "CastController"
        private const val POLL_MS = 1500L

        // Sin avance durante este rato = la tele se ha quedado muda (ver
        // checkStall). No se corta nada por debajo de este umbral.
        private const val STALL_MS = 40000L

        // Margen sobre la duracion antes de dar una pista por terminada cuando
        // la tele dejo de contestar.
        private const val END_MARGIN_S = 5

        // Tras un play/pausa/seek del usuario, el STOPPED que manda la tele es
        // parte de la maniobra, no el final de la cancion.
        private const val USER_ACTION_GRACE_MS = 8000L
    }

    private val main = Handler(Looper.getMainLooper())

    private val dlnaManager = DlnaManager(context)
    private val castManager = CastManager(context)

    private val knownDevices = mutableMapOf<String, KastDevice>()
    private var activeDevice: KastDevice? = null

    /** Avisos hacia Dart. Los pone [CastBridge]. */
    var onPosition: ((posSec: Int, durSec: Int, playing: Boolean) -> Unit)? = null
    var onTrackFinished: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null

    // --- Estado de la heuristica de fin de pista (identico a Kast) ---
    private var isPolling = false
    private var lastPos = 0
    private var stallCount = 0
    private var reachedEnd = false
    private var sawPlayback = false
    private var pausedOnDevice = false
    private var userPaused = false
    private var advanceScheduled = false
    private var isLiveTrack = false
    private var lastProgressAtMs = 0L
    private var lastUpdateAtMs = 0L
    private var lastUserActionAtMs = 0L
    private var lastKnownPos = 0
    private var lastKnownDur = 0
    private var lastKnownPlaying = false

    // --- Eventos GENA (la tele avisa ella sola, llega antes que el sondeo) ---
    private var genaServer: GenaServer? = null
    private var genaSid: String? = null
    private var genaDevice: DlnaDevice? = null
    private val genaHandler = Handler(Looper.getMainLooper())
    private var genaRenew: Runnable? = null

    fun isAvailable(): Boolean = castManager.isCastAvailable()

    // =====================================================================
    // Descubrimiento
    // =====================================================================

    fun startDiscovery() {
        castManager.startDiscovery()
    }

    fun stopDiscovery() {
        castManager.stopDiscovery()
    }

    /**
     * Busca receptores. Chromecast responde al momento (MediaRouter ya venia
     * escuchando); DLNA es un escaneo SSDP de unos segundos, asi que los
     * dispositivos se van entregando segun aparecen.
     */
    fun discover(onDevice: (KastDevice) -> Unit, onFinished: () -> Unit) {
        knownDevices.clear()
        castManager.startDiscovery()
        castManager.discoverDevices({ cast ->
            val device = KastDevice(cast.name, "cast", castDevice = cast)
            knownDevices[keyOf(device)] = device
            main.post { onDevice(device) }
        }, {})

        dlnaManager.discoverDevices({ dlna ->
            val device = KastDevice(dlna.name, "dlna", dlnaDevice = dlna)
            knownDevices[keyOf(device)] = device
            main.post { onDevice(device) }
        }, {
            main.post { onFinished() }
        })
    }

    fun keyOf(device: KastDevice): String = when (device.type) {
        "cast" -> "cast:" + (device.castDevice?.routeId ?: "")
        else -> "dlna:" + (device.dlnaDevice?.location ?: "")
    }

    // =====================================================================
    // Envio
    // =====================================================================

    /**
     * Manda una pista al receptor [deviceKey]. [localPath] gana a [url]: si la
     * cancion esta descargada se sirve el fichero desde el movil.
     *
     * Con DLNA todo pasa por [MediaServer] aunque sea un stream de internet,
     * porque DlnaManager deduce mime y perfil DLNA de la extension de la URL y
     * una URL de YouTube no tiene ninguna.
     */
    fun load(
        deviceKey: String,
        url: String?,
        localPath: String?,
        title: String,
        artist: String,
        artworkUrl: String?,
        isLive: Boolean,
        startSeconds: Int,
        durationMs: Long,
        onResult: (Boolean, String) -> Unit,
    ) {
        val device = knownDevices[deviceKey] ?: activeDevice?.takeIf { keyOf(it) == deviceKey }
        if (device == null) {
            onResult(false, "Dispositivo no encontrado")
            return
        }

        val needsServer = !localPath.isNullOrEmpty() || device.type == "dlna"

        if (!needsServer) {
            if (url.isNullOrEmpty()) {
                onResult(false, "Sin URL que enviar")
                return
            }
            send(device, url, guessMimeFromUrl(url), title, artist, artworkUrl, isLive, startSeconds, durationMs, onResult)
            return
        }

        // Preparar el servidor toca la red (mide el tamano del stream remoto),
        // y en el hilo principal eso revienta con NetworkOnMainThreadException:
        // el tamano se quedaba a cero, la respuesta salia sin Content-Length y
        // la tele devolvia UPnP 716.
        Thread {
            val server = MediaServer.get()
            val ok = server != null && (
                if (!localPath.isNullOrEmpty()) {
                    server.setLocalSource(localPath)
                } else if (!url.isNullOrEmpty()) {
                    server.setRemoteSource(url, null)
                } else {
                    false
                }
                )
            val mediaUrl = if (ok) server?.mediaUrl() else null
            val mime = server?.currentMime() ?: "audio/mp4"
            // Las canciones del movil traen la caratula como ruta de disco: si
            // se la mandamos tal cual al receptor no la ve y se queda con la
            // anterior, asi que se sirve por el mismo proxy.
            val artwork = when {
                server == null || artworkUrl == null || !artworkUrl.startsWith("/") -> artworkUrl
                server.setArtwork(artworkUrl) -> server.artworkUrl()
                else -> artworkUrl
            }
            main.post {
                if (server == null) {
                    onResult(false, "No se pudo abrir el servidor local")
                    return@post
                }
                if (!ok) {
                    onResult(false, "No se pudo preparar el audio")
                    return@post
                }
                if (mediaUrl.isNullOrEmpty()) {
                    onResult(false, "Sin conexion wifi")
                    return@post
                }
                send(device, mediaUrl, mime, title, artist, artwork, isLive, startSeconds, durationMs, onResult)
            }
        }.start()
    }

    /** Manda al receptor una URL ya lista. Siempre en el hilo principal: el SDK de Cast lo exige. */
    private fun send(
        device: KastDevice,
        mediaUrl: String,
        mime: String,
        title: String,
        artist: String,
        artworkUrl: String?,
        isLive: Boolean,
        startSeconds: Int,
        durationMs: Long,
        onResult: (Boolean, String) -> Unit,
    ) {
        activeDevice = device
        isLiveTrack = isLive
        resetTrackState()

        when (device.type) {
            "cast" -> {
                val cast = device.castDevice
                if (cast == null) { onResult(false, "Chromecast no valido"); return }
                // El fin de pista nativo del SDK es mas fiable que el sondeo:
                // trae ya el filtro de IDLE falso (cooldown + 50% de la pista).
                castManager.setOnTrackFinishedListener { finishTrack() }
                castManager.setOnSessionEndedListener {
                    if (activeDevice?.type == "cast") {
                        stopPolling()
                        activeDevice = null
                        onDisconnected?.invoke()
                    }
                }
                castManager.sendToDevice(
                    cast,
                    CastTrack(
                        url = mediaUrl,
                        title = title,
                        artist = artist,
                        artworkUrl = artworkUrl,
                        mimeType = mime,
                        isLive = isLive,
                        startSeconds = startSeconds,
                        durationMs = durationMs,
                    ),
                ) { ok, msg ->
                    main.post {
                        if (ok) startPolling()
                        onResult(ok, msg)
                    }
                }
            }
            else -> {
                val dlna = device.dlnaDevice
                if (dlna == null) { onResult(false, "Dispositivo DLNA no valido"); return }
                dlnaManager.sendToDevice(dlna, mediaUrl, title, artist, durationMs) { ok, msg ->
                    main.post {
                        if (ok) {
                            startPolling()
                            startGenaEvents(dlna)
                            if (startSeconds > 0) {
                                // Tras un SetAVTransportURI la tele necesita un
                                // respiro antes de aceptar el Seek.
                                main.postDelayed({ seek(startSeconds) }, 1200)
                            }
                        }
                        onResult(ok, msg)
                    }
                }
            }
        }
    }

    private fun guessMimeFromUrl(url: String): String {
        // Las URLs de googlevideo llevan el contenedor en la query (mime=audio%2Fmp4).
        val marker = "mime="
        val at = url.indexOf(marker)
        if (at >= 0) {
            val raw = url.substring(at + marker.length).substringBefore("&")
            val decoded = raw.replace("%2F", "/").replace("%2f", "/")
            if (decoded.startsWith("audio/")) return decoded
        }
        return MediaServer.mimeForPath(url.substringBefore("?"))
    }

    // =====================================================================
    // Controles
    // =====================================================================

    fun play() {
        userPaused = false
        lastUserActionAtMs = SystemClock.elapsedRealtime()
        val device = activeDevice ?: return
        when (device.type) {
            "cast" -> castManager.play { }
            else -> device.dlnaDevice?.let { dlnaManager.resume(it) { _, _ -> } }
        }
        lastKnownPlaying = true
    }

    fun pause() {
        userPaused = true
        lastUserActionAtMs = SystemClock.elapsedRealtime()
        val device = activeDevice ?: return
        when (device.type) {
            "cast" -> castManager.pause { }
            else -> device.dlnaDevice?.let { dlnaManager.pause(it) { _, _ -> } }
        }
        lastKnownPlaying = false
    }

    fun seek(seconds: Int) {
        lastUserActionAtMs = SystemClock.elapsedRealtime()
        val device = activeDevice ?: return
        when (device.type) {
            "cast" -> castManager.seek(seconds) { }
            else -> device.dlnaDevice?.let { dlnaManager.seek(it, seconds) { _, _ -> } }
        }
        lastKnownPos = seconds
    }

    /** Para la reproduccion pero mantiene la sesion: sirve entre canciones. */
    fun stop() {
        val device = activeDevice ?: return
        when (device.type) {
            "cast" -> { castManager.setOnTrackFinishedListener(null); castManager.stop { } }
            else -> device.dlnaDevice?.let { dlnaManager.stop(it) { _, _ -> } }
        }
        lastKnownPlaying = false
    }

    /** Sale del modo cast: corta, cierra la sesion y suelta la tele. */
    fun disconnect() {
        stop()
        stopPolling()
        stopGenaEvents()
        castManager.setOnSessionEndedListener(null)
        castManager.endSession()
        activeDevice = null
        userPaused = false
        lastProgressAtMs = 0L
    }

    // =====================================================================
    // Sondeo y fin de pista
    // =====================================================================

    private fun resetTrackState() {
        lastPos = 0
        stallCount = 0
        reachedEnd = false
        sawPlayback = false
        pausedOnDevice = false
        userPaused = false
        advanceScheduled = false
        lastUserActionAtMs = 0L
        lastProgressAtMs = SystemClock.elapsedRealtime()
        lastUpdateAtMs = lastProgressAtMs
        lastKnownPos = 0
        lastKnownDur = 0
        lastKnownPlaying = true
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (!isPolling) return
            val device = activeDevice
            when (device?.type) {
                "dlna" -> device.dlnaDevice?.let { d ->
                    dlnaManager.getPositionInfo(d) { pos, dur, state ->
                        main.post { handlePositionUpdate(pos, dur, state) }
                    }
                }
                "cast" -> castManager.getPositionInfo { pos, dur, state, _ ->
                    // IDLE en Cast es "no hay nada cargado": para la heuristica
                    // vale lo mismo que el STOPPED de una tele DLNA.
                    handlePositionUpdate(pos, dur, if (state == "IDLE") "STOPPED" else state)
                }
            }
            checkStall()
            if (isPolling) main.postDelayed(this, POLL_MS)
        }
    }

    private fun startPolling() {
        if (isPolling) return
        isPolling = true
        main.postDelayed(pollRunnable, POLL_MS)
    }

    private fun stopPolling() {
        isPolling = false
        main.removeCallbacks(pollRunnable)
    }

    /** Replica de handlePositionUpdate de Kast. */
    private fun handlePositionUpdate(pos: Int, dur: Int, stateStr: String) {
        val newPos = if (pos >= 0) pos else lastKnownPos
        val newDur = if (dur >= 0) dur else lastKnownDur
        val wasPlaying = lastKnownPlaying
        val isPlaying = stateStr.uppercase().contains("PLAYING")

        lastKnownPos = newPos
        lastKnownDur = newDur
        lastKnownPlaying = isPlaying
        onPosition?.invoke(newPos, newDur, isPlaying)
        CastLog.d(TAG, "poll pos=" + newPos + " dur=" + newDur + " estado=" + stateStr)

        // Una radio no acaba nunca: aqui no hay nada que detectar.
        if (isLiveTrack) return

        val s = stateStr.uppercase()
        val stopped = s.contains("STOPPED") || s.contains("NO_MEDIA")
        // Una pausa, venga de la app o del mando de la tele, es intencionada:
        // ni se salta ni cuenta como atasco.
        pausedOnDevice = s.contains("PAUSED")
        lastUpdateAtMs = SystemClock.elapsedRealtime()
        if (newPos > lastPos) {
            lastProgressAtMs = lastUpdateAtMs
            // Si la posicion avanza, la maniobra de pausa/reanudacion termino.
            lastUserActionAtMs = 0L
        }

        // Mientras carga, la tele contesta STOPPED con duracion 0, que es justo
        // lo que se interpretaria como "cancion terminada". No se hace caso de
        // nada hasta que confirme que esta reproduciendo.
        if (isPlaying && (newPos > 0 || newDur > 0)) sawPlayback = true

        // Marca de agua: hay teles que resetean la posicion a 0 al pasar a
        // STOPPED, asi que no podemos fiarnos de mirarla despues.
        if (newDur > 0 && newPos > 0 && (newDur - newPos) <= 2) reachedEnd = true

        // Caso A - fin natural: estaba sonando y ya no.
        val naturalEnd = wasPlaying && !isPlaying && sawPlayback && (reachedEnd || stopped)

        // Caso B - congelado al final: hay teles que se quedan en PLAYING con la
        // posicion clavada. Se salta tras 2 sondeos seguidos sin avanzar.
        var frozenEnd = false
        if (isPlaying && sawPlayback && newDur > 0 && newPos >= newDur - 1) {
            stallCount = if (newPos <= lastPos) stallCount + 1 else 0
            if (stallCount >= 2) frozenEnd = true
        } else {
            stallCount = 0
        }
        lastPos = newPos

        if (naturalEnd || frozenEnd) {
            CastLog.d(TAG, "fin de pista (" + (if (naturalEnd) "natural" else "congelado") +
                ") pos=" + newPos + " dur=" + newDur + " estado=" + stateStr)
            advanceAfterEnd(500)
        }
    }

    /**
     * Ultimo recurso: nadie ha dicho que la cancion haya acabado, pero hace rato
     * que no avanza. Nunca corta una pista en curso: mientras la tele diga que
     * esta reproduciendo solo se pasa a la siguiente cuando el reloj demuestra
     * que ya no puede quedar nada.
     */
    private fun checkStall() {
        if (isLiveTrack) return
        if (userPaused || pausedOnDevice || advanceScheduled || lastProgressAtMs == 0L) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastProgressAtMs < STALL_MS) return
        val elapsedSec = ((now - lastUpdateAtMs) / 1000L).toInt()
        val surelyOver = lastKnownDur > 0 &&
            lastKnownPos + elapsedSec >= lastKnownDur + END_MARGIN_S
        if (lastKnownPlaying && !surelyOver) return
        CastLog.w(TAG, "sin avance desde hace " + ((now - lastProgressAtMs) / 1000) + "s, paso a la siguiente")
        // Se desarma hasta que arranque de verdad la siguiente pista.
        lastProgressAtMs = 0L
        advanceAfterEnd(200)
    }

    /** Unico sitio desde el que se avisa de fin de pista. */
    private fun advanceAfterEnd(delayMs: Long) {
        if (advanceScheduled) return
        // En pausa no se avanza nunca, y justo despues de dar a play o de buscar
        // tampoco: el STOPPED que manda la tele ahi es parte de la maniobra.
        if (userPaused) return
        if (SystemClock.elapsedRealtime() - lastUserActionAtMs < USER_ACTION_GRACE_MS) return
        advanceScheduled = true
        stallCount = 0
        main.postDelayed({
            advanceScheduled = false
            finishTrack()
        }, delayMs)
    }

    private fun finishTrack() {
        sawPlayback = false
        reachedEnd = false
        onTrackFinished?.invoke()
    }

    // =====================================================================
    // GENA
    // =====================================================================

    private fun startGenaEvents(device: DlnaDevice) {
        if (device.eventUrl.isEmpty()) return
        if (genaDevice?.eventUrl == device.eventUrl && genaSid != null) return
        stopGenaEvents()
        val server = genaServer ?: GenaServer { state -> main.post { onRendererEvent(state) } }
            .also { genaServer = it }
        if (server.port == 0 && server.start() == 0) return
        genaDevice = device
        val ip = MediaServer.localIp() ?: return
        val callback = "http://" + ip + ":" + server.port + "/gena"
        dlnaManager.subscribeEvents(device, callback, null) { sid, seconds ->
            main.post {
                genaSid = sid
                if (sid != null) scheduleGenaRenew(device, callback, seconds)
                else Log.d(TAG, "el aparato no acepta eventos GENA, seguimos con el sondeo")
            }
        }
    }

    private fun scheduleGenaRenew(device: DlnaDevice, callback: String, seconds: Int) {
        genaRenew?.let { genaHandler.removeCallbacks(it) }
        val runnable = Runnable {
            dlnaManager.subscribeEvents(device, callback, genaSid) { sid, secs ->
                main.post {
                    genaSid = sid
                    // Si la renovacion falla se empieza de cero: puede que la
                    // tele se haya reiniciado y ya no reconozca el SID viejo.
                    if (sid != null) scheduleGenaRenew(device, callback, secs) else startGenaEvents(device)
                }
            }
        }
        genaRenew = runnable
        genaHandler.postDelayed(runnable, (seconds.coerceAtLeast(60) / 2) * 1000L)
    }

    private fun stopGenaEvents() {
        genaRenew?.let { genaHandler.removeCallbacks(it) }
        genaRenew = null
        val device = genaDevice
        val sid = genaSid
        if (device != null && sid != null) dlnaManager.unsubscribeEvents(device, sid)
        genaDevice = null
        genaSid = null
    }

    /** Cambio de estado que manda la tele por su cuenta. Llega antes que el sondeo. */
    private fun onRendererEvent(state: String) {
        val s = state.uppercase()
        if (s.contains("PLAYING")) {
            sawPlayback = true
            pausedOnDevice = false
            lastProgressAtMs = SystemClock.elapsedRealtime()
            lastUpdateAtMs = lastProgressAtMs
        }
        if (s.contains("PAUSED")) pausedOnDevice = true
        val ended = s.contains("STOPPED") || s.contains("NO_MEDIA")
        if (!ended || !sawPlayback || isLiveTrack) return
        CastLog.d(TAG, "GENA: la tele dice " + state + ", paso a la siguiente")
        advanceAfterEnd(500)
    }
}
