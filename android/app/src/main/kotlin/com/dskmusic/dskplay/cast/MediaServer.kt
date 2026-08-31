package com.dskmusic.dskplay.cast

import android.util.Log
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.URL

/**
 * Servidor HTTP en el movil que sirve a la tele el audio que suena en la app.
 * Portado del SimpleWebServer de Kast, recortado a lo que necesita un
 * reproductor de musica (fuera imagenes y origenes SMB/SFTP) y con un origen
 * nuevo: proxy de una URL remota.
 *
 * El proxy existe por DLNA: [DlnaManager] deduce el mime y el perfil
 * DLNA.ORG_PN de la EXTENSION de la URL, y una URL de YouTube no tiene
 * extension ninguna. Sirviendola desde aqui como /media/track.m4a la tele
 * recibe exactamente el mime, los rangos por bytes y las cabeceras que espera.
 */
class MediaServer private constructor(port: Int) : NanoHTTPD(null, port) {

    private var localFile: File? = null
    private var remoteUrl: String? = null
    private var artworkFile: File? = null

    // El Chromecast identifica el medio por su URL: sirviendo cada pista bajo
    // la misma /media/track.mp3 daba por cargada la anterior y repetia la
    // cancion cambiando solo el titulo. Un numero de serie por origen basta.
    private var sourceSeq = 0
    private var contentType: String = "audio/mp4"
    private var contentLength: Long = 0L

    companion object {
        private const val TAG = "CastMediaServer"
        private const val BASE_PORT = 8099
        private const val MAX_ATTEMPTS = 50
        private const val MAX_RETRIES = 5

        // Pixel negro 1x1: pantalla de transicion entre cargas en el Chromecast
        // (ver loadPlaceholder en CastManager), evita que la tele se quede con
        // la caratula anterior mientras bufferea la siguiente pista.
        private val blankPng: ByteArray by lazy {
            android.util.Base64.decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk" +
                    "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                android.util.Base64.DEFAULT,
            )
        }

        @Volatile
        private var instance: MediaServer? = null

        fun get(): MediaServer? {
            instance?.let { return it }
            synchronized(this) {
                instance?.let { return it }
                val port = findAvailablePort() ?: return null
                val server = MediaServer(port)
                return try {
                    server.start(SOCKET_READ_TIMEOUT, false)
                    Log.d(TAG, "Servidor en puerto " + port)
                    instance = server
                    server
                } catch (e: Exception) {
                    Log.e(TAG, "No arranca el servidor: " + e.message)
                    null
                }
            }
        }

        private fun findAvailablePort(): Int? {
            for (attempt in 0 until MAX_ATTEMPTS) {
                val port = BASE_PORT + attempt
                try {
                    ServerSocket(port).use { it.reuseAddress = true }
                    return port
                } catch (_: Exception) {
                }
            }
            return null
        }

        /**
         * IP del movil en la wifi. La tele solo puede pedirnos el audio por
         * aqui: 127.0.0.1 no le sirve de nada.
         */
        fun localIp(): String? {
            try {
                for (iface in NetworkInterface.getNetworkInterfaces()) {
                    if (!iface.isUp || iface.isLoopback) continue
                    for (addr in iface.inetAddresses) {
                        if (addr.isLoopbackAddress) continue
                        val ip = addr.hostAddress ?: continue
                        // IPv4 solo: hay teles que ni miran una URL con IPv6.
                        if (ip.contains(":")) continue
                        return ip
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "localIp error: " + e.message)
            }
            return null
        }

        private fun extensionFor(mime: String): String = when {
            mime.contains("mpeg") -> "mp3"
            mime.contains("flac") -> "flac"
            mime.contains("wav") -> "wav"
            mime.contains("opus") || mime.contains("ogg") -> "ogg"
            mime.contains("webm") -> "webm"
            mime.contains("aac") -> "aac"
            else -> "m4a"
        }

        fun mimeForPath(path: String): String {
            val lower = path.lowercase()
            return when {
                lower.endsWith(".mp3") -> "audio/mpeg"
                lower.endsWith(".flac") -> "audio/flac"
                lower.endsWith(".wav") -> "audio/wav"
                lower.endsWith(".ogg") || lower.endsWith(".opus") -> "audio/ogg"
                lower.endsWith(".webm") -> "audio/webm"
                lower.endsWith(".aac") -> "audio/aac"
                else -> "audio/mp4"
            }
        }
    }

    /** URL que hay que darle a la tele para el origen actual, o null si no hay red. */
    fun mediaUrl(): String? {
        val ip = localIp() ?: return null
        // El nombre no lo lee nadie, pero la extension SI: de ella salen el mime
        // y el perfil DLNA que manda DlnaManager.
        return "http://" + ip + ":" + listeningPort + "/media/" + sourceSeq + "/track." + extensionFor(contentType)
    }

    fun currentMime(): String = contentType

    /** Los archivos del movil traen la portada en disco, no en una URL. */
    fun setArtwork(path: String?): Boolean {
        val file = path?.let { File(it) }
        artworkFile = if (file != null && file.exists()) file else null
        return artworkFile != null
    }

    fun artworkUrl(): String? {
        val file = artworkFile ?: return null
        val ip = localIp() ?: return null
        return "http://" + ip + ":" + listeningPort + "/art/" + sourceSeq + "/" + file.name
    }

    /** Los dos origenes son excluyentes: cambiar sin limpiar serviria el archivo equivocado. */
    fun setLocalSource(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        localFile = file
        remoteUrl = null
        sourceSeq++
        contentType = mimeForPath(path)
        contentLength = file.length()
        return true
    }

    fun setRemoteSource(url: String, mimeHint: String?): Boolean {
        localFile = null
        remoteUrl = url
        sourceSeq++
        contentType = if (mimeHint.isNullOrEmpty()) "audio/mp4" else mimeHint
        contentLength = 0L
        probeRemote(url)
        return true
    }

    /**
     * Tamano y tipo reales del origen remoto. Se pide con Range 0-0 en vez de
     * HEAD porque hay CDNs (googlevideo entre ellos) que responden 405 a HEAD
     * pero contestan el Content-Range sin despeinarse.
     */
    private fun probeRemote(url: String, updateType: Boolean = true) {
        try {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                instanceFollowRedirects = true
                setRequestProperty("Range", "bytes=0-0")
            }
            conn.inputStream.use { it.read() }
            val range = conn.getHeaderField("Content-Range")
            val fromRange = range?.substringAfterLast("/")?.toLongOrNull()
            contentLength = fromRange ?: 0L
            val type = conn.contentType?.substringBefore(";")?.trim()
            if (updateType && type != null && type.startsWith("audio")) contentType = type
            conn.disconnect()
            CastLog.d(TAG, "origen remoto: " + contentType + ", " + contentLength + " bytes")
        } catch (e: Exception) {
            CastLog.w(TAG, "probeRemote fallo: " + e.message)
        }
    }

    /** [limit] es el primer byte que ya NO se sirve, o -1 si no hay tope. */
    private fun openAt(offset: Long, limit: Long): InputStream? {
        val url = remoteUrl
        if (url != null) return ResumableRemoteStream(url, offset, limit)
        val file = localFile ?: return null
        return try {
            val stream = FileInputStream(file)
            skipFully(stream, offset)
            stream
        } catch (e: Exception) {
            Log.e(TAG, "openAt local: " + e.message)
            null
        }
    }

    // skip() no garantiza saltar todo lo pedido de una vez. Si nos quedamos
    // cortos servimos el trozo desde el offset equivocado y la tele ve basura.
    private fun skipFully(stream: InputStream, offset: Long) {
        var skipped = 0L
        while (skipped < offset) {
            val n = stream.skip(offset - skipped)
            if (n > 0) skipped += n
            else if (stream.read() < 0) break
            else skipped++
        }
    }

    override fun serve(session: IHTTPSession): Response {
        if (session.uri == "/blank.png") {
            return newFixedLengthResponse(
                Response.Status.OK,
                "image/png",
                ByteArrayInputStream(blankPng),
                blankPng.size.toLong(),
            )
        }
        if (session.uri.startsWith("/art/")) {
            val file = artworkFile
                ?: return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404")
            val mime = when {
                file.name.endsWith(".png", true) -> "image/png"
                file.name.endsWith(".gif", true) -> "image/gif"
                else -> "image/jpeg"
            }
            return newFixedLengthResponse(
                Response.Status.OK,
                mime,
                FileInputStream(file),
                file.length(),
            )
        }
        if (!session.uri.startsWith("/media/")) {
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404")
        }
        return try {
            serveMedia(session)
        } catch (e: Exception) {
            Log.e(TAG, "serve: " + e.message, e)
            newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "Error")
        }
    }

    private fun serveMedia(session: IHTTPSession): Response {
        // Red de seguridad: sin tamano la respuesta sale sin Content-Length y
        // hay teles que devuelven UPnP 716. Si la medida inicial fallo se
        // reintenta aqui, que ya estamos en un hilo del servidor. El mime NO se
        // toca: el DIDL ya se mando anunciando el que hubiera entonces.
        val source = remoteUrl
        if (contentLength == 0L && source != null) probeRemote(source, updateType = false)

        val total = contentLength
        val rangeHeader = session.headers["range"]
        var start = 0L
        var end = if (total > 0) total - 1 else Long.MAX_VALUE

        if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
            val spec = rangeHeader.substring(6).trim()
            val dash = spec.indexOf('-')
            val fromSpec = if (dash >= 0) spec.substring(0, dash) else spec
            val toSpec = if (dash >= 0) spec.substring(dash + 1) else ""
            if (fromSpec.isEmpty()) {
                // Rango sufijo ("bytes=-N"): los ULTIMOS N bytes. Antes se
                // servia el principio del archivo, asi que la tele recibia
                // audio donde esperaba el indice del m4a y se plantaba a los
                // pocos segundos.
                val suffix = toSpec.toLongOrNull() ?: 0L
                if (total > 0 && suffix > 0) {
                    start = maxOf(0L, total - suffix)
                    end = total - 1
                }
            } else {
                start = fromSpec.toLongOrNull() ?: 0L
                if (toSpec.isNotEmpty()) toSpec.toLongOrNull()?.let { end = it }
            }
        }
        if (total > 0 && end >= total) end = total - 1
        val length = if (total > 0) end - start + 1 else -1L

        // HEAD: DlnaManager pregunta el tamano antes de mandar el DIDL. Abrir el
        // origen aqui seria descargar el archivo entero para tirarlo.
        val isHead = session.method == Method.HEAD
        CastLog.d(TAG, "serve " + session.method + " rango=" + rangeHeader + " -> " + start + "-" + end + "/" + total)
        val body: InputStream? = if (isHead) null else openAt(start, if (total > 0) end + 1 else -1L)
        if (!isHead && body == null) {
            return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404")
        }
        val stream = body ?: ByteArrayInputStream(ByteArray(0))

        val status = if (start > 0) Response.Status.PARTIAL_CONTENT else Response.Status.OK
        val response = if (length >= 0) {
            newFixedLengthResponse(status, contentType, stream, length)
        } else {
            // Directo sin longitud conocida (radio): chunked.
            newChunkedResponse(status, contentType, stream)
        }

        if (start > 0 && total > 0) {
            response.addHeader("Content-Range", "bytes " + start + "-" + end + "/" + total)
        }
        response.addHeader("Accept-Ranges", "bytes")
        response.addHeader("transferMode.dlna.org", "Streaming")
        response.addHeader(
            "contentFeatures.dlna.org",
            "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000",
        )
        // Cabecera propietaria Samsung: sin ella hay firmwares que ni intentan
        // abrir el stream.
        if (total > 0) response.addHeader("MediaInfo.sec", "SEC_Duration=0")
        return response
    }

    /**
     * Lectura del origen remoto que se reconecta por rangos donde se quedo.
     * googlevideo corta la conexion antes de tiempo con bastante alegria;
     * ExoPlayer lo disimula reconectando y aqui hay que hacer lo mismo: si no,
     * la tele ve el final del archivo a los pocos segundos, para, y la app lo
     * interpreta como fin de pista y salta a la siguiente.
     */
    private class ResumableRemoteStream(
        private val url: String,
        private var offset: Long,
        private val limit: Long,
    ) : InputStream() {

        private var stream: InputStream? = null
        private var conn: HttpURLConnection? = null
        private var retries = 0

        private fun ensure(): InputStream? {
            stream?.let { return it }
            if (limit in 0..offset) return null
            return try {
                val c = (URL(url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15000
                    readTimeout = 30000
                    instanceFollowRedirects = true
                    setRequestProperty("Range", "bytes=" + offset + "-")
                }
                conn = c
                val body = c.inputStream
                CastLog.d(
                    TAG,
                    "upstream desde " + offset + ": HTTP " + c.responseCode +
                        " rango=" + c.getHeaderField("Content-Range"),
                )
                // Hay URLs (y CDNs) que se saltan la cabecera Range y devuelven
                // el archivo entero: si no se descarta lo ya servido, la tele
                // recibe el principio otra vez donde esperaba continuacion.
                if (c.responseCode == HttpURLConnection.HTTP_OK && offset > 0) {
                    CastLog.w(TAG, "el origen ignoro el Range, se salta a mano hasta " + offset)
                    skipFully(body, offset)
                }
                body.also { stream = it }
            } catch (e: Exception) {
                CastLog.w(TAG, "reconexion fallida en " + offset + ": " + e.message)
                null
            }
        }

        private fun closeCurrent() {
            try { stream?.close() } catch (_: Exception) {}
            try { conn?.disconnect() } catch (_: Exception) {}
            stream = null
            conn = null
        }

        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (limit in 0..offset) return -1
            var want = len
            if (limit >= 0) want = minOf(want.toLong(), limit - offset).toInt()
            if (want <= 0) return -1

            while (retries <= MAX_RETRIES) {
                val src = ensure() ?: return -1
                val n = try {
                    src.read(b, off, want)
                } catch (e: Exception) {
                    CastLog.w(TAG, "lectura cortada en " + offset + ": " + e.message)
                    -1
                }
                if (n > 0) {
                    offset += n
                    retries = 0
                    return n
                }
                closeCurrent()
                // Fin de verdad: no queda archivo por servir.
                if (limit < 0 || offset >= limit) return -1
                retries++
                CastLog.w(TAG, "corte en " + offset + " de " + limit + ", reintento " + retries)
            }
            return -1
        }

        private fun skipFully(stream: InputStream, target: Long) {
            var skipped = 0L
            while (skipped < target) {
                val n = stream.skip(target - skipped)
                if (n > 0) skipped += n
                else if (stream.read() < 0) break
                else skipped++
            }
        }

        override fun close() = closeCurrent()
    }
}
