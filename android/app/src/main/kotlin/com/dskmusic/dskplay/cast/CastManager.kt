package com.dskmusic.dskplay.cast

import android.content.Context
import android.util.Log
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient

class CastManager(private val context: Context) {

    companion object {
        private const val TAG = "CastManager"
    }

    private var castContext: CastContext? = null

    private val castSelector = androidx.mediarouter.media.MediaRouteSelector.Builder()
        .addControlCategory(com.google.android.gms.cast.CastMediaControlIntent.categoryForCast("CC1AD845"))
        .build()
    private val knownCastDevices = mutableMapOf<String, CastDevice>()
    private var discoveryCallback: androidx.mediarouter.media.MediaRouter.Callback? = null

    // MediaRouter tarda un par de segundos en publicar las rutas, asi que los
    // Chromecast se entregan segun aparecen igual que los DLNA. Devolver solo
    // la lista que hubiera en ese instante dejaba la hoja sin Chromecast.
    private var deviceListener: ((CastDevice) -> Unit)? = null

    // Listener nativo de fin de pista — más fiable que polling para Samsung
    private var onTrackFinished: (() -> Unit)? = null
    private var mediaClientListener: RemoteMediaClient.Listener? = null
    private var sessionEndedListener: SessionManagerListener<CastSession>? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    // Cooldown proporcional: ignora IDLE hasta que hayan pasado al menos MIN_PLAY_RATIO de la duración
    private var ignoreIdleUntil = 0L
    private var currentTrackDurationMs = 0L
    private val MIN_COOLDOWN_MS = 3000L
    private val MIN_PLAY_RATIO = 0.5

    init {
        try {
            castContext = CastContext.getSharedInstance(context)
            Log.d(TAG, "Cast SDK iniciado OK")
        } catch (e: Exception) {
            Log.e(TAG, "Cast SDK no disponible: ${e.message}")
        }
    }

    private fun getClient(): RemoteMediaClient? {
        return try {
            val session = castContext?.sessionManager?.currentCastSession
            if (session != null && session.isConnected) session.remoteMediaClient else null
        } catch (e: Exception) {
            Log.w(TAG, "getClient error: ${e.message}")
            null
        }
    }

    // Registra un callback que se dispara cuando la pista termina de forma nativa
    fun setOnTrackFinishedListener(listener: (() -> Unit)?) {
        onTrackFinished = listener
        // Si hay cliente activo, registrar el listener ahora
        getClient()?.let { attachClientListener(it) }
    }

    private fun attachClientListener(client: RemoteMediaClient) {
        // Quitar listener anterior si existe
        mediaClientListener?.let {
            try { client.removeListener(it) } catch (_: Exception) {}
        }

        val listener = object : RemoteMediaClient.Listener {
            override fun onStatusUpdated() {
                val status = client.mediaStatus ?: return
                val state = status.playerState
                val reason = status.idleReason

                if (state == MediaStatus.PLAYER_STATE_IDLE &&
                    reason == MediaStatus.IDLE_REASON_FINISHED) {

                    val now = System.currentTimeMillis()

                    // Cooldown mínimo: ignorar si aún no han pasado MIN_COOLDOWN_MS desde el load
                    if (now < ignoreIdleUntil) {
                        Log.d(TAG, "IDLE_REASON_FINISHED ignorado (cooldown mínimo activo, ${ignoreIdleUntil - now}ms restantes)")
                        return
                    }

                    // Comprobación por posición: si dur es conocido, exigir que pos >= 50% de la duración
                    val durMs = currentTrackDurationMs
                    val posMs = client.approximateStreamPosition
                    if (durMs > 0 && posMs < durMs * MIN_PLAY_RATIO) {
                        Log.d(TAG, "IDLE_REASON_FINISHED ignorado (pos=${posMs}ms < 50% de dur=${durMs}ms)")
                        return
                    }

                    Log.d(TAG, "Pista terminada (IDLE_REASON_FINISHED) pos=${posMs}ms dur=${durMs}ms")
                    mainHandler.post { onTrackFinished?.invoke() }
                }
            }
            override fun onMetadataUpdated() {}
            override fun onQueueStatusUpdated() {}
            override fun onPreloadStatusUpdated() {}
            override fun onSendingRemoteMediaRequest() {}
            override fun onAdBreakStatusUpdated() {}
        }

        mediaClientListener = listener
        client.addListener(listener)
        Log.d(TAG, "RemoteMediaClient.Listener registrado")
    }

    fun startDiscovery() {
        if (castContext == null) return
        // Un solo callback por sesion de busqueda: registrar otro dejaria el
        // anterior colgado escaneando.
        if (discoveryCallback != null) return
        val mediaRouter = androidx.mediarouter.media.MediaRouter.getInstance(context)
        val cb = object : androidx.mediarouter.media.MediaRouter.Callback() {
            override fun onRouteAdded(router: androidx.mediarouter.media.MediaRouter, route: androidx.mediarouter.media.MediaRouter.RouteInfo) {
                if (route.matchesSelector(castSelector) && !route.isDefault) {
                    CastLog.d(TAG, "Chromecast detectado: ${route.name}")
                    publish(route)
                }
            }
            override fun onRouteRemoved(router: androidx.mediarouter.media.MediaRouter, route: androidx.mediarouter.media.MediaRouter.RouteInfo) {
                knownCastDevices.remove(route.id)
            }
            override fun onRouteChanged(router: androidx.mediarouter.media.MediaRouter, route: androidx.mediarouter.media.MediaRouter.RouteInfo) {
                if (route.matchesSelector(castSelector) && !route.isDefault) {
                    publish(route)
                }
            }
        }
        discoveryCallback = cb
        // Escaneo activo: es lo que se hace mientras hay un selector de
        // dispositivos abierto, y encuentra los Chromecast en segundos.
        mediaRouter.addCallback(
            castSelector,
            cb,
            androidx.mediarouter.media.MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY or
                androidx.mediarouter.media.MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN,
        )
        // Rutas que MediaRouter ya conocia de antes de abrir la hoja.
        mediaRouter.routes.forEach { route ->
            if (route.matchesSelector(castSelector) && !route.isDefault) publish(route)
        }
    }

    private fun publish(route: androidx.mediarouter.media.MediaRouter.RouteInfo) {
        val device = CastDevice(name = route.name, routeId = route.id)
        knownCastDevices[route.id] = device
        deviceListener?.invoke(device)
    }

    fun stopDiscovery() {
        deviceListener = null
        val cb = discoveryCallback ?: return
        try { androidx.mediarouter.media.MediaRouter.getInstance(context).removeCallback(cb) } catch (_: Exception) {}
        discoveryCallback = null
    }

    fun discoverDevices(onDeviceFound: (CastDevice) -> Unit, onFinished: () -> Unit) {
        if (castContext == null) {
            CastLog.w(TAG, "sin Cast SDK: no se buscan Chromecast")
            onFinished()
            return
        }
        deviceListener = onDeviceFound
        knownCastDevices.values.forEach { onDeviceFound(it) }
        onFinished()
    }

    fun sendToDevice(
        device: CastDevice,
        track: CastTrack,
        onResult: (Boolean, String) -> Unit
    ) {
        val mediaUrl = track.url
        val ctx = castContext ?: run { onResult(false, "Cast SDK no disponible"); return }

        try {
            val existingSession = ctx.sessionManager.currentCastSession
            if (existingSession != null && existingSession.isConnected) {
                Log.d(TAG, "Sesión activa, cargando directo: $mediaUrl")
                loadMedia(existingSession, track, onResult, showPlaceholder = true)
                return
            }

            val mediaRouter = androidx.mediarouter.media.MediaRouter.getInstance(context)
            val route = mediaRouter.routes.find { it.id == device.routeId }
            if (route == null) { onResult(false, "Ruta no encontrada"); return }
            mediaRouter.selectRoute(route)

            ctx.sessionManager.addSessionManagerListener(object : SessionManagerListener<CastSession> {
                override fun onSessionStarted(session: CastSession, sessionId: String) {
                    ctx.sessionManager.removeSessionManagerListener(this, CastSession::class.java)
                    loadMedia(session, track, onResult)
                }
                override fun onSessionStartFailed(session: CastSession, error: Int) {
                    ctx.sessionManager.removeSessionManagerListener(this, CastSession::class.java)
                    onResult(false, "Error conectando (código $error)")
                }
                override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
                    ctx.sessionManager.removeSessionManagerListener(this, CastSession::class.java)
                    loadMedia(session, track, onResult)
                }
                override fun onSessionEnded(session: CastSession, error: Int) {}
                override fun onSessionEnding(session: CastSession) {}
                override fun onSessionResumeFailed(session: CastSession, error: Int) {}
                override fun onSessionResuming(session: CastSession, sessionId: String) {}
                override fun onSessionStarting(session: CastSession) {}
                override fun onSessionSuspended(session: CastSession, reason: Int) {}
            }, CastSession::class.java)

        } catch (e: Exception) {
            Log.e(TAG, "sendToDevice error: ${e.message}", e)
            onResult(false, "Error: ${e.message}")
        }
    }

    private fun loadMedia(
        session: CastSession,
        track: CastTrack,
        onResult: (Boolean, String) -> Unit,
        showPlaceholder: Boolean = false
    ) {
        try {
            val mediaUrl = track.url
            val mimeType = track.mimeType
            val isVideo = mimeType.startsWith("video/")
            val isAudio = mimeType.startsWith("audio/")
            val mediaType = when {
                isVideo -> MediaMetadata.MEDIA_TYPE_MOVIE
                isAudio -> MediaMetadata.MEDIA_TYPE_MUSIC_TRACK
                else -> MediaMetadata.MEDIA_TYPE_PHOTO
            }

            val metadata = MediaMetadata(mediaType).apply {
                putString(MediaMetadata.KEY_TITLE, track.title)
                if (track.artist.isNotEmpty()) {
                    putString(MediaMetadata.KEY_ARTIST, track.artist)
                    putString(MediaMetadata.KEY_ALBUM_ARTIST, track.artist)
                }
                // La caratula es lo unico que se ve en la tele mientras suena.
                track.artworkUrl?.takeIf { it.startsWith("http") }?.let {
                    addImage(com.google.android.gms.common.images.WebImage(android.net.Uri.parse(it)))
                }
            }

            val mediaInfo = MediaInfo.Builder(mediaUrl)
                .setStreamType(
                    // Una radio o un directo no tienen final ni barra de
                    // progreso: marcarlos BUFFERED hace que el receptor intente
                    // calcular una duracion que no existe y se atasque.
                    if (track.isLive) MediaInfo.STREAM_TYPE_LIVE
                    else MediaInfo.STREAM_TYPE_BUFFERED
                )
                .setContentType(mimeType)
                .setContentUrl(mediaUrl)
                .setMetadata(metadata)
                .apply { if (track.durationMs > 0) setStreamDuration(track.durationMs) }
                .build()

            val request = MediaLoadRequestData.Builder()
                .setMediaInfo(mediaInfo)
                .setAutoplay(true)
                .setCurrentTime(track.startSeconds * 1000L)
                .build()

            val client = session.remoteMediaClient ?: run {
                onResult(false, "RemoteMediaClient no disponible")
                return
            }

            // Registrar listener nativo en este cliente
            attachClientListener(client)

            // Cargar directamente sin stop() previo — evita el error "not available"
            // El load() reemplaza el contenido actual de forma segura
            if (showPlaceholder) {
                // Pantalla negra breve mientras se prepara el contenido real,
                // para que el TV no se quede mostrando el contenido anterior mientras bufferea
                loadPlaceholder(client, mediaUrl) {
                    doLoad(client, request, onResult)
                }
            } else {
                doLoad(client, request, onResult)
            }

        } catch (e: Exception) {
            Log.e(TAG, "loadMedia error: ${e.message}", e)
            onResult(false, "Error: ${e.message}")
        }
    }

    private fun loadPlaceholder(client: RemoteMediaClient, mediaUrl: String, onDone: () -> Unit) {
        try {
            val baseUrl = mediaUrl.substringBefore("/media/", mediaUrl)
            val placeholderUrl = "$baseUrl/blank.png"
            val mediaInfo = MediaInfo.Builder(placeholderUrl)
                .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
                .setContentType("image/png")
                .setContentUrl(placeholderUrl)
                .build()
            val request = MediaLoadRequestData.Builder().setMediaInfo(mediaInfo).setAutoplay(true).build()
            client.load(request)?.setResultCallback { onDone() } ?: onDone()
        } catch (e: Exception) {
            Log.w(TAG, "loadPlaceholder error: ${e.message}")
            onDone()
        }
    }

    private fun doLoad(
        client: RemoteMediaClient,
        request: MediaLoadRequestData,
        onResult: (Boolean, String) -> Unit
    ) {
        try {
            // Cooldown mínimo tras load — ignorar IDLE durante al menos MIN_COOLDOWN_MS
            ignoreIdleUntil = System.currentTimeMillis() + MIN_COOLDOWN_MS
            // Guardar duración del stream para la comprobación proporcional
            currentTrackDurationMs = request.mediaInfo?.streamDuration ?: 0L
            Log.d(TAG, "doLoad: cooldown=${MIN_COOLDOWN_MS}ms durStream=${currentTrackDurationMs}ms")
            client.load(request)?.setResultCallback { result ->
                if (result.status.isSuccess) {
                    onResult(true, "Reproduciendo en Cast")
                } else {
                    Log.w(TAG, "Load falló: ${result.status.statusMessage} code=${result.status.statusCode}")
                    onResult(false, "Error: ${result.status.statusMessage}")
                }
            } ?: onResult(false, "RemoteMediaClient no disponible")
        } catch (e: Exception) {
            Log.e(TAG, "doLoad error: ${e.message}", e)
            onResult(false, "Error: ${e.message}")
        }
    }

    fun pause(onResult: (Boolean) -> Unit) {
        try { getClient()?.pause()?.setResultCallback { onResult(it.status.isSuccess) } ?: onResult(false) }
        catch (e: Exception) { Log.w(TAG, "pause error: ${e.message}"); onResult(false) }
    }

    fun play(onResult: (Boolean) -> Unit) {
        try { getClient()?.play()?.setResultCallback { onResult(it.status.isSuccess) } ?: onResult(false) }
        catch (e: Exception) { Log.w(TAG, "play error: ${e.message}"); onResult(false) }
    }

    fun stop(onResult: (Boolean) -> Unit) {
        onTrackFinished = null
        mediaClientListener?.let {
            try { getClient()?.removeListener(it) } catch (_: Exception) {}
        }
        mediaClientListener = null
        try {
            getClient()?.stop()?.setResultCallback { onResult(it.status.isSuccess) } ?: onResult(true)
        } catch (e: Exception) {
            Log.w(TAG, "stop error: ${e.message}")
            onResult(false)
        }
    }

    fun seek(seconds: Int, onResult: (Boolean) -> Unit) {
        try { getClient()?.seek(seconds * 1000L)?.setResultCallback { onResult(it.status.isSuccess) } ?: onResult(false) }
        catch (e: Exception) { Log.w(TAG, "seek error: ${e.message}"); onResult(false) }
    }

    fun getPositionInfo(onResult: (pos: Int, dur: Int, state: String, idleReason: Int) -> Unit) {
        try {
            val client = getClient() ?: run { onResult(-1, -1, "", MediaStatus.IDLE_REASON_NONE); return }
            val status = client.mediaStatus ?: run { onResult(-1, -1, "BUFFERING", MediaStatus.IDLE_REASON_NONE); return }
            val pos = (client.approximateStreamPosition / 1000).toInt()
            val dur = (status.mediaInfo?.streamDuration?.div(1000) ?: -1L).toInt()
            val idleReason = status.idleReason
            val state = when (status.playerState) {
                MediaStatus.PLAYER_STATE_PLAYING -> "PLAYING"
                MediaStatus.PLAYER_STATE_PAUSED -> "PAUSED"
                MediaStatus.PLAYER_STATE_BUFFERING,
                MediaStatus.PLAYER_STATE_LOADING -> "BUFFERING"
                MediaStatus.PLAYER_STATE_IDLE -> "IDLE"
                else -> "STOPPED"
            }
            onResult(pos, dur, state, idleReason)
        } catch (e: Exception) {
            Log.w(TAG, "getPositionInfo error: ${e.message}")
            onResult(-1, -1, "", MediaStatus.IDLE_REASON_NONE)
        }
    }

    fun isCastAvailable(): Boolean = castContext != null

    fun isConnected(): Boolean = getClient() != null

    /**
     * Cierra la sesion con el Chromecast (no solo la reproduccion): es lo que
     * devuelve la tele a su pantalla de inicio al salir del modo cast.
     */
    fun endSession() {
        onTrackFinished = null
        mediaClientListener = null
        try {
            castContext?.sessionManager?.endCurrentSession(true)
        } catch (e: Exception) {
            Log.w(TAG, "endSession error: ${e.message}")
        }
    }

    /**
     * Avisa cuando la sesion se cae por su cuenta (el usuario desconecta desde
     * la tele, se apaga, se pierde el wifi). Sin esto la app se quedaria
     * creyendo que sigue casteando y no devolveria el sonido al movil.
     */
    fun setOnSessionEndedListener(listener: (() -> Unit)?) {
        val ctx = castContext ?: return
        sessionEndedListener?.let {
            try { ctx.sessionManager.removeSessionManagerListener(it, CastSession::class.java) } catch (_: Exception) {}
        }
        sessionEndedListener = null
        if (listener == null) return

        val l = object : SessionManagerListener<CastSession> {
            override fun onSessionEnded(session: CastSession, error: Int) { mainHandler.post { listener() } }
            override fun onSessionSuspended(session: CastSession, reason: Int) {}
            override fun onSessionResumeFailed(session: CastSession, error: Int) { mainHandler.post { listener() } }
            override fun onSessionStartFailed(session: CastSession, error: Int) { mainHandler.post { listener() } }
            override fun onSessionStarted(session: CastSession, sessionId: String) {}
            override fun onSessionEnding(session: CastSession) {}
            override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {}
            override fun onSessionResuming(session: CastSession, sessionId: String) {}
            override fun onSessionStarting(session: CastSession) {}
        }
        sessionEndedListener = l
        ctx.sessionManager.addSessionManagerListener(l, CastSession::class.java)
    }
}