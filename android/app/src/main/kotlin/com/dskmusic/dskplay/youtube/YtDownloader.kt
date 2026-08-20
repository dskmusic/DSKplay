package com.dskmusic.dskplay.youtube

import java.net.InetSocketAddress
import java.net.Proxy
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import java.util.concurrent.TimeUnit

/**
 * Downloader de NewPipeExtractor basado en OkHttp. Mismo patrón que
 * DSK LoFi (YtDownloader.kt), reducido a lo imprescindible.
 *
 * Inicialización (una sola vez, antes de cualquier llamada a NewPipe):
 *     NewPipe.init(YtDownloader.getInstance())
 */
class YtDownloader private constructor() : Downloader() {

    @Volatile
    private var client: OkHttpClient = buildClient(null)

    private fun buildClient(proxy: Proxy?): OkHttpClient = OkHttpClient.Builder()
        .readTimeout(30, TimeUnit.SECONDS)
        .connectTimeout(30, TimeUnit.SECONDS)
        .apply { if (proxy != null) proxy(proxy) }
        .build()

    /**
     * Enruta las peticiones por un proxy HTTP `ip:puerto`, o directo si es null.
     * Es estado global del proceso: sustituye al cliente proxificado que
     * ProxyManager creaba por cada YoutubeExplode.
     */
    fun setProxy(hostPort: String?) {
        val proxy = hostPort
            ?.split(":")
            ?.takeIf { it.size == 2 }
            ?.let { (host, port) ->
                port.toIntOrNull()?.let { Proxy(Proxy.Type.HTTP, InetSocketAddress(host, it)) }
            }
        client = buildClient(proxy)
    }

    companion object {
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        @Volatile
        private var instance: YtDownloader? = null

        fun getInstance(): YtDownloader =
            instance ?: synchronized(this) {
                instance ?: YtDownloader().also { instance = it }
            }
    }

    override fun execute(request: Request): Response {
        val httpMethod = request.httpMethod()
        val url = request.url()
        val headers = request.headers()
        val dataToSend = request.dataToSend()

        val requestBody = dataToSend?.toRequestBody(null, 0, dataToSend.size)

        val builder = okhttp3.Request.Builder()
            .method(httpMethod, requestBody)
            .url(url)
            .addHeader("User-Agent", USER_AGENT)

        for ((headerName, headerValueList) in headers) {
            if (headerValueList.size > 1) {
                builder.removeHeader(headerName)
                for (value in headerValueList) builder.addHeader(headerName, value)
            } else if (headerValueList.size == 1) {
                builder.header(headerName, headerValueList[0])
            }
        }

        val response = client.newCall(builder.build()).execute()

        if (response.code == 429) {
            response.close()
            throw ReCaptchaException("reCaptcha Challenge requested", url)
        }

        val body = response.body?.string()
        val latestUrl = response.request.url.toString()

        return Response(
            response.code,
            response.message,
            response.headers.toMultimap(),
            body,
            latestUrl,
        )
    }
}
