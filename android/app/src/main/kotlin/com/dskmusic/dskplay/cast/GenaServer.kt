package com.dskmusic.dskplay.cast

import android.util.Log
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Servidor minimo para los avisos GENA (el "eventing" de UPnP): la TV manda un NOTIFY cada vez
 * que cambia de estado, asi que se entera uno de que un video ha terminado en el momento, sin
 * adivinarlo por la posicion.
 *
 * No vale reutilizar NanoHTTPD: su enum Method no conoce NOTIFY y contesta 400 antes de llegar a
 * serve(), con lo que el aviso se perderia. Cuarenta lineas de socket salen mas baratas que
 * pelearse con la libreria.
 */
class GenaServer(private val onTransportState: (String) -> Unit) {

    @Volatile private var running = false
    private var socket: ServerSocket? = null

    var port: Int = 0
        private set

    fun start(): Int {
        if (running) return port
        return try {
            val server = ServerSocket()
            server.reuseAddress = true
            server.bind(InetSocketAddress(0))
            socket = server
            port = server.localPort
            running = true
            Thread { accept(server) }.start()
            Log.d(TAG, "servidor de eventos escuchando en el puerto $port")
            port
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo abrir el servidor de eventos: ${e.message}")
            0
        }
    }

    fun stop() {
        running = false
        runCatching { socket?.close() }
        socket = null
        port = 0
    }

    private fun accept(server: ServerSocket) {
        while (running) {
            val client = try {
                server.accept()
            } catch (e: Exception) {
                break
            }
            Thread { handle(client) }.start()
        }
    }

    private fun handle(client: Socket) {
        try {
            client.soTimeout = SOCKET_TIMEOUT_MS
            val input = client.getInputStream()
            var length = 0
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                if (line.startsWith("CONTENT-LENGTH", ignoreCase = true)) {
                    length = line.substringAfter(':').trim().toIntOrNull() ?: 0
                }
            }
            val body = ByteArray(length.coerceAtMost(MAX_BODY))
            var read = 0
            while (read < body.size) {
                val n = input.read(body, read, body.size - read)
                if (n <= 0) break
                read += n
            }
            // El 200 no es opcional: si no contestamos, la TV da la suscripcion por muerta.
            val out = client.getOutputStream()
            out.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            out.flush()
            parse(String(body, 0, read, Charsets.UTF_8))
        } catch (e: Exception) {
            Log.w(TAG, "aviso descartado: ${e.message}")
        } finally {
            runCatching { client.close() }
        }
    }

    private fun parse(body: String) {
        // El LastChange viaja como XML escapado dentro del XML, hay que desescaparlo primero.
        // El &amp; va el ultimo o se desharia dos veces lo que no toca.
        val plain = body
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&apos;", "'")
            .replace("&amp;", "&")
        val state = STATE.find(plain)?.groupValues?.get(1) ?: return
        Log.d(TAG, "TransportState = $state")
        onTransportState(state)
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
        }
    }

    companion object {
        private const val TAG = "GenaServer"
        private const val SOCKET_TIMEOUT_MS = 5000
        private const val MAX_BODY = 64 * 1024
        private val STATE = Regex("TransportState[^>]*val=\"([^\"]+)\"", RegexOption.IGNORE_CASE)
    }
}
