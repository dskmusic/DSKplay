package com.dskmusic.dskplay.cast

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.*
import java.util.concurrent.TimeUnit

data class DlnaDevice(
    val name: String,
    val location: String,
    val controlUrl: String = "",
    // URL de suscripcion a eventos de AVTransport (GENA). Vacia = el aparato no los publica.
    val eventUrl: String = ""
)

class DlnaManager(private val context: Context) {

    // Guardamos estos datos del archivo actual para seek por bytes en Samsung
    private var currentMediaUrl: String = ""

    companion object {
        private const val SSDP_ADDRESS = "239.255.255.250"
        private const val SSDP_PORT = 1900
        private const val SCAN_TIMEOUT_MS = 5000
        private const val TAG = "DlnaManager"

        // User-Agent reconocible
        private const val USER_AGENT = "Kast/1.0 UPnP/1.0 DLNADOC/1.50"

        // Duracion que se pide para la suscripcion a eventos; se renueva a la mitad.
        private const val EVENT_TIMEOUT_S = 300
    }

    private val ssdpMessage = "M-SEARCH * HTTP/1.1\r\nHOST: $SSDP_ADDRESS:$SSDP_PORT\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"

    fun discoverDevices(onDeviceFound: (DlnaDevice) -> Unit, onFinished: () -> Unit) {
        Thread {
            var multicastLock: WifiManager.MulticastLock? = null
            try {
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                multicastLock = wifiManager.createMulticastLock("dlna_lock").apply {
                    setReferenceCounted(true)
                    acquire()
                }

                val wifiInfo = wifiManager.connectionInfo
                val ipInt = wifiInfo.ipAddress
                val ipBytes = byteArrayOf(
                    (ipInt and 0xFF).toByte(),
                    (ipInt shr 8 and 0xFF).toByte(),
                    (ipInt shr 16 and 0xFF).toByte(),
                    (ipInt shr 24 and 0xFF).toByte()
                )
                val wifiInetAddress = InetAddress.getByAddress(ipBytes)
                Log.d(TAG, "Usando interfaz WiFi: $wifiInetAddress")

                val group = InetAddress.getByName(SSDP_ADDRESS)
                val socket = MulticastSocket(null).apply {
                    reuseAddress = true
                    bind(InetSocketAddress(wifiInetAddress, 0))
                    soTimeout = SCAN_TIMEOUT_MS
                    networkInterface = NetworkInterface.getByInetAddress(wifiInetAddress)
                    joinGroup(InetSocketAddress(group, SSDP_PORT), NetworkInterface.getByInetAddress(wifiInetAddress))
                }

                val messageBytes = ssdpMessage.toByteArray(Charsets.UTF_8)
                socket.send(DatagramPacket(messageBytes, messageBytes.size, group, SSDP_PORT))
                Log.d(TAG, "M-SEARCH enviado")

                val foundLocations = mutableSetOf<String>()
                val buffer = ByteArray(4096)
                val endTime = System.currentTimeMillis() + SCAN_TIMEOUT_MS

                while (System.currentTimeMillis() < endTime) {
                    try {
                        val packet = DatagramPacket(buffer, buffer.size)
                        socket.receive(packet)
                        val response = String(packet.data, 0, packet.length, Charsets.UTF_8)
                        Log.d(TAG, "Respuesta recibida de ${packet.address}: ${response.take(200)}")
                        parseDevice(response)?.let { device ->
                            if (foundLocations.add(device.location)) {
                                fetchDeviceDetails(device, onDeviceFound)
                            }
                        }
                    } catch (e: SocketTimeoutException) {
                        break
                    } catch (e: Exception) {
                        Log.w(TAG, "Error recibiendo: ${e.message}")
                    }
                }
                socket.close()

            } catch (e: Exception) {
                Log.e(TAG, "Error general DLNA: ${e.message}", e)
            } finally {
                multicastLock?.release()
                onFinished()
            }
        }.start()
    }

    private fun parseDevice(response: String): DlnaDevice? {
        if (!response.contains("200 OK", ignoreCase = true) &&
            !response.contains("NOTIFY", ignoreCase = true)) return null
        val location = Regex("LOCATION:\\s*(\\S+)", RegexOption.IGNORE_CASE)
            .find(response)?.groupValues?.get(1)?.trim() ?: return null
        val name = Regex("SERVER:\\s*(.+)", RegexOption.IGNORE_CASE)
            .find(response)?.groupValues?.get(1)?.trim() ?: "Dispositivo desconocido"
        Log.d(TAG, "Dispositivo parseado: $name @ $location")
        return DlnaDevice(name = name, location = location)
    }

    private fun fetchDeviceDetails(device: DlnaDevice, onDeviceFound: (DlnaDevice) -> Unit) {
        try {
            val url = URL(device.location)
            val connection = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 3000
                readTimeout = 3000
            }
            val xml = connection.inputStream.bufferedReader().readText()
            connection.disconnect()

            val friendlyName = Regex("<friendlyName>([^<]+)</friendlyName>")
                .find(xml)?.groupValues?.get(1)?.trim() ?: device.name

            if (!xml.contains("AVTransport", ignoreCase = true)) {
                Log.d(TAG, "Descartado (no es renderer): $friendlyName")
                return
            }

            val controlUrl = parseServiceUrl(xml, device.location, "controlURL")
            val eventUrl = parseServiceUrl(xml, device.location, "eventSubURL")
            Log.d(TAG, "Renderer encontrado: $friendlyName, controlUrl: $controlUrl, eventUrl: $eventUrl")

            onDeviceFound(DlnaDevice(
                name = friendlyName,
                location = device.location,
                controlUrl = controlUrl,
                eventUrl = eventUrl
            ))
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo obtener detalles de ${device.location}: ${e.message}")
        }
    }

    // Sirve para controlURL y para eventSubURL: dentro del bloque de AVTransport van seguidas.
    private fun parseServiceUrl(xml: String, baseLocation: String, tag: String): String {
        val pattern = Regex(
            "<serviceType>\\s*urn:schemas-upnp-org:service:AVTransport[^<]*</serviceType>.*?<$tag>\\s*([^<]+?)\\s*</$tag>",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)
        )
        val match = pattern.find(xml)?.groupValues?.get(1)?.trim() ?: return ""
        Log.d(TAG, "$tag raw: '$match'")
        if (match.startsWith("http")) return match

        val urlBase = Regex("<URLBase>\\s*([^<]+?)\\s*</URLBase>", RegexOption.IGNORE_CASE)
            .find(xml)?.groupValues?.get(1)?.trim()

        val base = URL(if (!urlBase.isNullOrEmpty()) urlBase else baseLocation)
        val path = if (match.startsWith("/")) match else "/$match"

        val port = if (base.port != -1) {
            ":${base.port}"
        } else {
            ""
        }
        val finalUrl = "${base.protocol}://${base.host}$port$path"
        Log.d(TAG, "$tag final: '$finalUrl'")
        return finalUrl
    }

    // --- Eventos GENA ---

    // HttpURLConnection no admite verbos que no sean los suyos (SUBSCRIBE le da ProtocolException),
    // asi que estas dos van por OkHttp, que ya esta en el proyecto por WebDAV.
    private val eventClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Suscribe los avisos de AVTransport, o los renueva si se pasa el [sid] de la suscripcion en
     * curso. Devuelve el SID (null si el aparato no soporta eventos) y los segundos que dura.
     */
    fun subscribeEvents(
        device: DlnaDevice,
        callbackUrl: String,
        sid: String?,
        onResult: (String?, Int) -> Unit
    ) {
        if (device.eventUrl.isEmpty()) {
            onResult(null, 0)
            return
        }
        Thread {
            try {
                val builder = Request.Builder()
                    .url(device.eventUrl)
                    .method("SUBSCRIBE", null)
                    .header("TIMEOUT", "Second-$EVENT_TIMEOUT_S")
                    .header("USER-AGENT", USER_AGENT)
                if (sid.isNullOrEmpty()) {
                    builder.header("CALLBACK", "<$callbackUrl>").header("NT", "upnp:event")
                } else {
                    builder.header("SID", sid)
                }
                eventClient.newCall(builder.build()).execute().use { response ->
                    val newSid = response.header("SID") ?: sid
                    val seconds = response.header("TIMEOUT")
                        ?.substringAfter("Second-", "")?.toIntOrNull() ?: EVENT_TIMEOUT_S
                    Log.d(TAG, "SUBSCRIBE ${response.code} sid=$newSid timeout=$seconds")
                    onResult(if (response.isSuccessful) newSid else null, seconds)
                }
            } catch (e: Exception) {
                Log.w(TAG, "SUBSCRIBE fallo: ${e.message}")
                onResult(null, 0)
            }
        }.start()
    }

    fun unsubscribeEvents(device: DlnaDevice, sid: String) {
        if (device.eventUrl.isEmpty()) return
        Thread {
            runCatching {
                eventClient.newCall(
                    Request.Builder()
                        .url(device.eventUrl)
                        .method("UNSUBSCRIBE", null)
                        .header("SID", sid)
                        .build()
                ).execute().close()
            }
        }.start()
    }

    fun sendToDevice(device: DlnaDevice, mediaUrl: String, title: String, artist: String = "", durationMs: Long = 0L, onResult: (Boolean, String) -> Unit) {
        if (device.controlUrl.isEmpty()) {
            onResult(false, "No se encontró la URL de control del dispositivo")
            return
        }
        Thread {
            try {
                CastLog.d(TAG, "Enviando a ${device.name}: $mediaUrl")

                val mime = getMimeType(mediaUrl)
                val upnpClass = getUpnpClass(mediaUrl)
                val transferMode = if (upnpClass.contains("imageItem")) "Interactive" else "Streaming"

                val stopBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:Stop>
</s:Body>
</s:Envelope>"""

                try {
                    sendSoapAction(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#Stop",
                        stopBody,
                        emptyMap()
                    )
                } catch (e: Exception) {
                    Log.d(TAG, "Stop previo no aplicable: ${e.message}")
                }
                Thread.sleep(500)

                val isImage = upnpClass.contains("imageItem")
                val isAudio = upnpClass.contains("audioItem")
                val isVideo = !isImage && !isAudio

                val dlnaPn = getDlnaProfile(mediaUrl, mime)
                val pnPart = if (dlnaPn.isNotEmpty()) "DLNA.ORG_PN=$dlnaPn;" else ""

                // Para vídeo usar protocolInfo con flags Samsung correctos
                val protocolInfo = if (isVideo) {
                    "http-get:*:$mime:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
                } else {
                    val dlnaOp = if (isImage) "00" else "11"
                    val dlnaFlags = if (isImage) "00D00000000000000000000000000000"
                    else "01700000000000000000000000000000"
                    val contentFeatures = "${pnPart}DLNA.ORG_OP=$dlnaOp;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags"
                    "http-get:*:$mime:$contentFeatures"
                }

                val contentFeatures = if (isVideo) "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000" else {
                    val dlnaOp = if (isImage) "00" else "11"
                    val dlnaFlags = if (isImage) "00D00000000000000000000000000000"
                    else "01700000000000000000000000000000"
                    "${pnPart}DLNA.ORG_OP=$dlnaOp;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags"
                }
                val safeTitle = escapeXml(title)
                val safeUrl = escapeXml(mediaUrl)

                val fileSize = fetchContentLength(mediaUrl)
                val sizeAttr = if (fileSize > 0) " size=\"$fileSize\"" else ""
                // Duracion declarada: el m4a adaptativo de YouTube es un MP4
                // fragmentado y hay firmwares que leen del contenedor la
                // duracion de un fragmento (10s), tocan eso y paran. Con el
                // dato en el DIDL el renderer se fia de los metadatos.
                val durationAttr = if (durationMs > 0) " duration=\"${formatDlnaDuration(durationMs)}\"" else ""
                currentMediaUrl = mediaUrl
                CastLog.d(TAG, "sendToDevice: mime=$mime clase=$upnpClass perfil=$dlnaPn size=$fileSize")

                val nowIso = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                    .format(java.util.Date())
                val itemId = System.currentTimeMillis().toString()

                // Para vídeo declaramos resolución estándar 1280x720 aunque el vídeo sea diferente
                // Samsung filtra por resolución declarada en el DIDL antes de intentar reproducir
                val resolutionAttr = if (isVideo) " resolution=\"1280x720\"" else ""

                val didl = """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:sec="http://www.sec.co.kr/"><item id="$itemId" parentID="0" restricted="1"><dc:title>$safeTitle</dc:title><dc:creator>${escapeXml(artist.ifEmpty { "DSK Play" })}</dc:creator><dc:date>$nowIso</dc:date><upnp:class>$upnpClass</upnp:class><res protocolInfo="$protocolInfo"$sizeAttr$durationAttr$resolutionAttr>$safeUrl</res></item></DIDL-Lite>"""
                val didlEscaped = escapeXml(didl)
                val metaData = didlEscaped

                val setUriBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<CurrentURI>$safeUrl</CurrentURI>
<CurrentURIMetaData>$metaData</CurrentURIMetaData>
</u:SetAVTransportURI>
</s:Body>
</s:Envelope>"""

                val extraHeaders = if (isVideo) {
                    mapOf("transferMode.dlna.org" to transferMode)
                } else {
                    mapOf(
                        "transferMode.dlna.org" to transferMode,
                        "contentFeatures.dlna.org" to contentFeatures
                    )
                }

                // Reintento único: es la llamada crítica que arranca el siguiente medio, y la más
                // afectada por una TV lenta a mitad de un cambio de pista (timeout puntual de red).
                try {
                    sendSoapAction(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI",
                        setUriBody,
                        extraHeaders
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "SetAVTransportURI falló, reintentando una vez: ${e.message}")
                    Thread.sleep(800)
                    sendSoapAction(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI",
                        setUriBody,
                        extraHeaders
                    )
                }

                Thread.sleep(1500)

                val playBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<Speed>1</Speed>
</u:Play>
</s:Body>
</s:Envelope>"""

                // Mismo reintento que en SetAVTransportURI: si la tele sigue
                // masticando el cambio de pista contesta 701 "Transition not
                // available" y basta con esperar un poco.
                try {
                    sendSoapAction(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#Play",
                        playBody,
                        emptyMap()
                    )
                } catch (e: Exception) {
                    CastLog.w(TAG, "Play fallo (${e.message}), reintento")
                    Thread.sleep(1000)
                    sendSoapAction(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#Play",
                        playBody,
                        emptyMap()
                    )
                }
                onResult(true, "Reproduciendo en ${device.name}")

            } catch (e: Exception) {
                Log.e(TAG, "Error enviando a dispositivo: ${e.message}", e)
                onResult(false, "Error: ${e.message}")
            }
        }.start()
    }

    // Posición guardada cuando la TV no soporta Pause y hacemos Stop
    var pausedPositionSeconds: Int = -1

    fun pause(device: DlnaDevice, onResult: (Boolean, String) -> Unit) {
        if (device.controlUrl.isEmpty()) {
            onResult(false, "Sin URL de control")
            return
        }
        // Log del stack trace para identificar quién llama a pause()
        Log.w(TAG, "pause() llamado desde: ${Thread.currentThread().stackTrace.take(8).joinToString(" > ") { "${it.className.substringAfterLast('.')}.${it.methodName}" }}")
        Thread {
            try {
                val state = queryTransportState(device)
                Log.d(TAG, "pause(): transportState='$state'")

                val body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:Pause>
</s:Body>
</s:Envelope>"""

                try {
                    sendSoapAction(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#Pause",
                        body,
                        emptyMap()
                    )
                    pausedPositionSeconds = -1 // Pausa real: no necesitamos seek al reanudar
                    onResult(true, "Pausado")
                } catch (e: Exception) {
                    Log.w(TAG, "Pause rechazado (estado=$state): ${e.message}. Guardando posición y haciendo Stop.")

                    // Guardar posición actual antes de hacer Stop
                    val posBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:GetPositionInfo>
</s:Body>
</s:Envelope>"""
                    val posResp = try { sendSoapActionWithResponse(device.controlUrl, "urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo", posBody) } catch (_: Exception) { "" }
                    val relTime = Regex("<RelTime[^>]*>([^<]+)</RelTime>").find(posResp)?.groupValues?.get(1)?.trim() ?: ""
                    pausedPositionSeconds = parseHms(relTime)
                    Log.d(TAG, "pause(): posición guardada = $pausedPositionSeconds seg (relTime='$relTime')")

                    val stopBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:Stop>
</s:Body>
</s:Envelope>"""
                    try {
                        sendSoapAction(
                            device.controlUrl,
                            "urn:schemas-upnp-org:service:AVTransport:1#Stop",
                            stopBody,
                            emptyMap()
                        )
                        onResult(true, "Parado (la TV no acepta pausa)")
                    } catch (e2: Exception) {
                        pausedPositionSeconds = -1
                        onResult(false, "La TV no acepta pausa ni stop: ${e2.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error en pause: ${e.message}", e)
                onResult(false, "Error: ${e.message}")
            }
        }.start()
    }

    fun resume(device: DlnaDevice, onResult: (Boolean, String) -> Unit) {
        if (device.controlUrl.isEmpty()) {
            onResult(false, "Sin URL de control")
            return
        }
        Thread {
            try {
                val state = queryTransportState(device)
                Log.d(TAG, "resume(): transportState='$state', pausedPositionSeconds=$pausedPositionSeconds")

                val playBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<Speed>1</Speed>
</u:Play>
</s:Body>
</s:Envelope>"""
                sendSoapAction(
                    device.controlUrl,
                    "urn:schemas-upnp-org:service:AVTransport:1#Play",
                    playBody,
                    emptyMap()
                )

                // Si la TV no soportó Pause y guardamos posición con Stop, hacemos Seek
                if (pausedPositionSeconds > 0) {
                    Log.d(TAG, "resume(): haciendo seek a $pausedPositionSeconds seg")
                    Thread.sleep(800) // Dar tiempo a que la TV empiece a reproducir
                    val target = formatHms(pausedPositionSeconds)
                    val seekBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<Unit>REL_TIME</Unit>
<Target>$target</Target>
</u:Seek>
</s:Body>
</s:Envelope>"""
                    try {
                        sendSoapAction(device.controlUrl, "urn:schemas-upnp-org:service:AVTransport:1#Seek", seekBody, emptyMap())
                    } catch (e: Exception) {
                        Log.w(TAG, "resume(): seek fallback falló: ${e.message}")
                    }
                    pausedPositionSeconds = -1
                }

                onResult(true, "Reproduciendo")
            } catch (e: Exception) {
                Log.e(TAG, "Error en play: ${e.message}", e)
                onResult(false, "Error: ${e.message}")
            }
        }.start()
    }

    private fun queryTransportState(device: DlnaDevice): String {
        return try {
            val body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:GetTransportInfo>
</s:Body>
</s:Envelope>"""
            val resp = sendSoapActionWithResponse(
                device.controlUrl,
                "urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo",
                body
            )
            Regex("<CurrentTransportState>([^<]+)</CurrentTransportState>")
                .find(resp)?.groupValues?.get(1)?.trim() ?: ""
        } catch (e: Exception) {
            Log.w(TAG, "queryTransportState falló: ${e.message}")
            ""
        }
    }

    fun stop(device: DlnaDevice, onResult: (Boolean, String) -> Unit) {
        if (device.controlUrl.isEmpty()) {
            onResult(false, "Sin URL de control")
            return
        }
        Thread {
            try {
                val body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:Stop>
</s:Body>
</s:Envelope>"""
                sendSoapAction(
                    device.controlUrl,
                    "urn:schemas-upnp-org:service:AVTransport:1#Stop",
                    body,
                    emptyMap()
                )
                onResult(true, "Detenido")
            } catch (e: Exception) {
                Log.e(TAG, "Error en stop: ${e.message}", e)
                onResult(false, "Error: ${e.message}")
            }
        }.start()
    }

    fun seek(device: DlnaDevice, seconds: Int, onResult: (Boolean, String) -> Unit) {
        if (device.controlUrl.isEmpty()) {
            onResult(false, "Sin URL de control")
            return
        }
        Thread {
            try {
                val target = formatHms(seconds)
                val state = queryTransportState(device)
                Log.d(TAG, "seek(): state=$state target=$target")

                // Si está STOPPED (Samsung usó Stop como Pause), arrancar primero
                if (state.equals("STOPPED", ignoreCase = true) || state.isEmpty()) {
                    try {
                        sendSoapAction(device.controlUrl, "urn:schemas-upnp-org:service:AVTransport:1#Play", buildPlayBody(), emptyMap())
                        Thread.sleep(600)
                    } catch (e: Exception) {
                        Log.w(TAG, "seek(): Play previo falló: ${e.message}")
                    }
                }

                val seekBody = buildSeekBody("REL_TIME", target)
                try {
                    sendSoapAction(device.controlUrl, "urn:schemas-upnp-org:service:AVTransport:1#Seek", seekBody, emptyMap())
                    pausedPositionSeconds = -1
                    Log.d(TAG, "seek(): OK")
                    onResult(true, "Seek a $target")
                } catch (e: Exception) {
                    Log.w(TAG, "seek(): falló (${e.message}) — dispositivo no soporta seek")
                    onResult(false, "Seek no soportado en este dispositivo")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error en seek: ${e.message}", e)
                onResult(false, "Error: ${e.message}")
            }
        }.start()
    }

    fun getPositionInfo(device: DlnaDevice, onResult: (Int, Int, String) -> Unit) {
        if (device.controlUrl.isEmpty()) {
            onResult(-1, -1, "")
            return
        }
        Thread {
            try {
                val body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:GetPositionInfo>
</s:Body>
</s:Envelope>"""
                val resp = sendSoapActionWithResponse(
                    device.controlUrl,
                    "urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo",
                    body
                )
                Log.d(TAG, "GetPositionInfo raw: ${resp.take(600)}")
                val rel = Regex("<RelTime[^>]*>([^<]+)</RelTime>").find(resp)?.groupValues?.get(1)?.trim() ?: ""
                var dur = Regex("<TrackDuration[^>]*>([^<]+)</TrackDuration>").find(resp)?.groupValues?.get(1)?.trim() ?: ""
                // Algunos Samsung devuelven NOT_IMPLEMENTED o 0:00:00 en TrackDuration
                // Intentar obtenerla de MediaInfo como fallback
                if (dur.isBlank() || dur == "0:00:00" || dur.contains("NOT_IMPLEMENTED", ignoreCase = true)) {
                    dur = Regex("<CurrentTrackDuration[^>]*>([^<]+)</CurrentTrackDuration>").find(resp)?.groupValues?.get(1)?.trim() ?: ""
                }

                val stateBody = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
</u:GetTransportInfo>
</s:Body>
</s:Envelope>"""
                val stateResp = try {
                    sendSoapActionWithResponse(
                        device.controlUrl,
                        "urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo",
                        stateBody
                    )
                } catch (_: Exception) { "" }
                val state = Regex("<CurrentTransportState>([^<]+)</CurrentTransportState>")
                    .find(stateResp)?.groupValues?.get(1)?.trim() ?: ""

                onResult(parseHms(rel), parseHms(dur), state)
            } catch (e: Exception) {
                Log.w(TAG, "getPositionInfo falló: ${e.message}")
                onResult(-1, -1, "")
            }
        }.start()
    }

    /** El DIDL quiere H:MM:SS.mmm, no el H:MM:SS de las acciones SOAP. */
    private fun formatDlnaDuration(ms: Long): String {
        val total = ms / 1000
        return "%d:%02d:%02d.000".format(total / 3600, (total % 3600) / 60, total % 60)
    }

    private fun formatHms(seconds: Int): String {
        val s = seconds.coerceAtLeast(0)
        val h = s / 3600
        val m = (s % 3600) / 60
        val sec = s % 60
        return "%d:%02d:%02d".format(h, m, sec)
    }

    private fun parseHms(s: String): Int {
        if (s.isBlank()) return -1
        return try {
            val parts = s.split(":").map { it.trim().toDouble().toInt() }
            when (parts.size) {
                3 -> parts[0] * 3600 + parts[1] * 60 + parts[2]
                2 -> parts[0] * 60 + parts[1]
                1 -> parts[0]
                else -> -1
            }
        } catch (_: Exception) { -1 }
    }

    private fun sendSoapActionWithResponse(
        controlUrl: String,
        soapAction: String,
        body: String
    ): String {
        val bodyBytes = body.toByteArray(Charsets.UTF_8)
        val url = URL(controlUrl)
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
            setRequestProperty("SOAPAction", "\"$soapAction\"")
            setRequestProperty("Connection", "close")
            setRequestProperty("User-Agent", USER_AGENT)
            doOutput = true
            // 8s en vez de 5s: algunas Smart TV (Samsung incluida) tardan más en responder
            // al SOAP durante el cambio de medio, sobre todo si venían de bufferear el anterior.
            connectTimeout = 8000
            readTimeout = 8000
            setFixedLengthStreamingMode(bodyBytes.size)
        }
        connection.outputStream.use { it.write(bodyBytes) }
        val code = connection.responseCode
        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.bufferedReader()?.readText() ?: ""
        connection.disconnect()
        return text
    }

    private fun sendSoapAction(
        controlUrl: String,
        soapAction: String,
        body: String,
        extraHeaders: Map<String, String>
    ) {
        val bodyBytes = body.toByteArray(Charsets.UTF_8)

        val url = URL(controlUrl)
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
            setRequestProperty("SOAPAction", "\"$soapAction\"")
            setRequestProperty("Connection", "close")
            setRequestProperty("User-Agent", USER_AGENT)
            for ((key, value) in extraHeaders) {
                setRequestProperty(key, value)
            }
            doOutput = true
            // 8s en vez de 5s: algunas Smart TV (Samsung incluida) tardan más en responder
            // al SOAP durante el cambio de medio, sobre todo si venían de bufferear el anterior.
            connectTimeout = 8000
            readTimeout = 8000
            setFixedLengthStreamingMode(bodyBytes.size)
        }
        connection.outputStream.use { it.write(bodyBytes) }
        val code = connection.responseCode
        Log.d(TAG, "SOAP $soapAction → $code (URL: $controlUrl)")

        if (code !in 200..299) {
            val errorBody = try {
                connection.errorStream?.bufferedReader()?.readText() ?: ""
            } catch (e: Exception) { "" }
            connection.disconnect()
            Log.w(TAG, "SOAP $soapAction FALLO ($code): ${errorBody.take(500)}")
            val upnpCode = Regex("<errorCode>\\s*(\\d+)\\s*</errorCode>")
                .find(errorBody)?.groupValues?.get(1) ?: ""
            val upnpDesc = Regex("<errorDescription>\\s*([^<]+)\\s*</errorDescription>")
                .find(errorBody)?.groupValues?.get(1)?.trim() ?: ""
            val msg = if (upnpCode.isNotEmpty()) "HTTP $code — UPnP $upnpCode: $upnpDesc"
            else "HTTP $code"
            throw java.io.IOException(msg)
        }
        connection.disconnect()
    }

    private fun escapeXml(s: String): String = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;")

    private fun getMimeType(url: String): String {
        val lower = url.lowercase()
        return when {
            lower.contains(".jpg") || lower.contains(".jpeg") -> "image/jpeg"
            lower.contains(".png") -> "image/png"
            lower.contains(".gif") -> "image/gif"
            lower.contains(".mp3") -> "audio/mpeg"
            lower.contains(".flac") -> "audio/flac"
            lower.contains(".wav") -> "audio/wav"
            lower.contains(".aac") -> "audio/aac"
            lower.contains(".m4a") -> "audio/mp4"
            lower.contains(".opus") || lower.contains(".ogg") -> "audio/ogg"
            lower.contains(".webm") -> "audio/webm"
            lower.contains(".mp4") -> "video/mp4"
            lower.contains(".m4v") -> "video/mp4"
            // MKV y AVI: Samsung los acepta mejor con video/mpeg o video/mp4
            // que con sus mime types nativos que muchos firmwares rechazan
            lower.contains(".mkv") -> "video/x-mkv"
            lower.contains(".avi") -> "video/avi"
            lower.contains(".ts")  -> "video/mpeg"
            lower.contains(".mov") -> "video/quicktime"
            lower.contains(".wmv") -> "video/x-ms-wmv"
            else -> "video/mp4"
        }
    }

    private fun getUpnpClass(url: String): String {
        val lower = url.lowercase()
        return when {
            lower.contains(".jpg") || lower.contains(".jpeg") ||
                    lower.contains(".png") || lower.contains(".gif") -> "object.item.imageItem.photo"
            lower.contains(".mp3") || lower.contains(".flac") ||
                    lower.contains(".wav") || lower.contains(".m4a") ||
                    lower.contains(".aac") || lower.contains(".opus") ||
                    lower.contains(".ogg") || lower.contains(".webm") ->
                "object.item.audioItem.musicTrack"
            else -> "object.item.videoItem.movie"
        }
    }

    private fun buildPlayBody() = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<Speed>1</Speed>
</u:Play>
</s:Body>
</s:Envelope>"""

    private fun buildSeekBody(unit: String, target: String) = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<Unit>$unit</Unit>
<Target>$target</Target>
</u:Seek>
</s:Body>
</s:Envelope>"""

    private fun fetchContentLength(mediaUrl: String): Long {
        return try {
            val url = URL(mediaUrl)
            val connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "HEAD"
                connectTimeout = 2000
                readTimeout = 2000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", USER_AGENT)
            }
            val len = connection.contentLengthLong
            connection.disconnect()
            Log.d(TAG, "Content-Length de $mediaUrl: $len")
            len
        } catch (e: Exception) {
            Log.w(TAG, "HEAD falló para $mediaUrl: ${e.message}")
            -1L
        }
    }

    private fun getDlnaProfile(url: String, mime: String): String {
        val lower = url.lowercase()
        return when {
            // Vídeo — perfiles Samsung probados
            lower.endsWith(".mp4") || mime == "video/mp4" -> ""
            lower.endsWith(".mkv") -> ""  // Samsung no acepta DLNA_PN para MKV — sin perfil es más compatible
            lower.endsWith(".avi") -> ""  // Igual con AVI
            lower.endsWith(".ts")  -> "MPEG_TS_SD_EU_ISO"
            lower.endsWith(".m4v") -> "AVC_MP4_BL_CIF15_AAC_520"
            // Audio
            lower.endsWith(".mp3") -> "MP3"
            lower.endsWith(".flac") -> "FLAC"
            lower.endsWith(".wav") -> "LPCM"
            lower.endsWith(".aac") -> "AAC_ISO_320"
            lower.endsWith(".m4a") -> "AAC_ISO_320"
            // Imagen — Samsung tiene límite de resolución con JPEG_LRG (máx 4096px)
            // Usamos JPEG_MED (1024px) solo si fue redimensionada, si no JPEG_LRG
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "JPEG_LRG"
            lower.endsWith(".png") -> "PNG_LRG"
            lower.endsWith(".gif") -> "GIF_LRG"
            else -> ""
        }
    }
}