package com.dskmusic.dskplay.youtube

import org.schabi.newpipe.extractor.Image
import org.schabi.newpipe.extractor.InfoItem
import org.schabi.newpipe.extractor.ListExtractor
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.Page
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.channel.ChannelInfo
import org.schabi.newpipe.extractor.channel.ChannelInfoItem
import org.schabi.newpipe.extractor.localization.ContentCountry
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.playlist.PlaylistInfo
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.StreamType

/**
 * Toda la extraccion con NewPipeExtractor, SIN nada de Android ni de Flutter.
 *
 * Esa separacion no es decorativa: asi NewPipeSmokeTest ejecuta exactamente
 * este codigo contra YouTube de verdad en la JVM, en vez de una copia parecida
 * que puede divergir. [NewPipeBridge] solo pone los hilos y el MethodChannel.
 *
 * Las claves de los mapas son las que espera `lib/services/newpipe.dart`.
 */
object NewPipeExtraction {

    private val yt = ServiceList.YouTube

    fun init() {
        if (NewPipe.getDownloader() == null) {
            NewPipe.init(YtDownloader.getInstance(), deviceLocalization(), deviceCountry())
        }
    }

    /**
     * Idioma y pais del movil. YouTube devuelve resultados distintos segun
     * `hl`/`gl`, asi que buscar desde Espana como si fuera ingles-EEUU daba
     * resultados peores. Si el sistema no da pais (p.ej. solo "es"), se cae a
     * US, que es lo que habia fijo antes.
     */
    private fun deviceLocalization(): Localization {
        val locale = java.util.Locale.getDefault()
        return Localization(
            locale.language.ifBlank { "en" },
            locale.country.ifBlank { "US" },
        )
    }

    private fun deviceCountry(): ContentCountry =
        ContentCountry(java.util.Locale.getDefault().country.ifBlank { "US" })

    fun setProxy(hostPort: String?) = YtDownloader.getInstance().setProxy(hostPort)

    // ---------------------------------------------------------------- busqueda

    fun search(query: String, filters: List<String>, pages: Int): List<Map<String, Any?>> {
        val extractor = yt.getSearchExtractor(yt.searchQHFactory.fromQuery(query, filters, ""))
        extractor.fetchPage()
        return collect(extractor.initialPage, pages, Int.MAX_VALUE) { extractor.getPage(it) }
    }

    fun suggestions(query: String): List<String> = yt.suggestionExtractor.suggestionList(query)

    // ------------------------------------------------------------------ video

    fun video(id: String) = videoInfoMap(StreamInfo.getInfo(yt, watchUrl(id)))

    fun related(id: String): List<Map<String, Any?>> =
        StreamInfo.getInfo(yt, watchUrl(id)).relatedItems
            .mapNotNull { it as? StreamInfoItem }
            .mapNotNull { streamItemMap(it) }

    /** Detalles del video + sus streams de solo-audio, de mayor a menor bitrate. */
    fun streams(id: String): Map<String, Any?> {
        val info = StreamInfo.getInfo(yt, watchUrl(id))
        val audio = info.audioStreams
            .filter { it.isUrl && !it.content.isNullOrBlank() }
            .sortedByDescending { it.averageBitrate }
            .map {
                mapOf(
                    "url" to it.content,
                    "bitrate" to it.averageBitrate,
                    "itag" to it.itag,
                    "codec" to (it.codec ?: ""),
                    "mime" to (it.format?.mimeType ?: ""),
                    "container" to (it.format?.suffix ?: ""),
                )
            }
        return videoInfoMap(info) + mapOf("audio" to audio, "hlsUrl" to (info.hlsUrl ?: ""))
    }

    // ------------------------------------------------------------------ listas

    fun playlist(id: String): Map<String, Any?> {
        val info = PlaylistInfo.getInfo(yt, playlistUrl(id))
        return mapOf(
            "type" to "playlist",
            "id" to info.id,
            "title" to (info.name ?: ""),
            "author" to (info.uploaderName ?: ""),
            "channelId" to channelIdOf(info.uploaderUrl),
            "streamCount" to info.streamCount,
            "thumbnail" to bestImage(info.thumbnails),
            "description" to (info.description?.content ?: ""),
        )
    }

    fun playlistItems(id: String, limit: Int): List<Map<String, Any?>> {
        val extractor = yt.getPlaylistExtractor(playlistUrl(id))
        extractor.fetchPage()
        return collect(extractor.initialPage, Int.MAX_VALUE, limit) { extractor.getPage(it) }
    }

    // ----------------------------------------------------------------- canales

    fun channel(id: String): Map<String, Any?> {
        val info = ChannelInfo.getInfo(yt, channelUrl(id))
        return mapOf(
            "type" to "channel",
            "id" to info.id,
            "title" to (info.name ?: ""),
            "description" to (info.description ?: ""),
            "subscriberCount" to info.subscriberCount,
            "thumbnail" to bestImage(info.avatars),
            "banner" to bestImage(info.banners),
        )
    }

    /** tab: "videos" | "playlists" | "albums"... (ver ChannelTabs de NewPipe). */
    fun channelTab(id: String, tab: String, limit: Int): List<Map<String, Any?>> {
        val extractor = yt.getChannelTabExtractorFromId(id, tab)
        extractor.fetchPage()
        return collect(extractor.initialPage, Int.MAX_VALUE, limit) { extractor.getPage(it) }
    }

    // ------------------------------------------------------------------ mapeos

    private fun infoItemMap(item: InfoItem): Map<String, Any?>? = when (item) {
        is StreamInfoItem -> streamItemMap(item)
        is PlaylistInfoItem -> playlistItemMap(item)
        is ChannelInfoItem -> channelItemMap(item)
        else -> null
    }

    private fun streamItemMap(s: StreamInfoItem): Map<String, Any?>? {
        val id = idOf(s.url) ?: return null
        return mapOf(
            "type" to "video",
            "id" to id,
            "title" to (s.name ?: ""),
            "author" to (s.uploaderName ?: ""),
            "channelId" to channelIdOf(s.uploaderUrl),
            "duration" to s.duration,
            "isLive" to (s.streamType == StreamType.LIVE_STREAM),
            "thumbnail" to bestImage(s.thumbnails),
        )
    }

    private fun playlistItemMap(p: PlaylistInfoItem): Map<String, Any?>? {
        val id = playlistIdOf(p.url) ?: return null
        return mapOf(
            "type" to "playlist",
            "id" to id,
            "title" to (p.name ?: ""),
            "author" to (p.uploaderName ?: ""),
            "channelId" to channelIdOf(p.uploaderUrl),
            "streamCount" to p.streamCount,
            "thumbnail" to bestImage(p.thumbnails),
        )
    }

    private fun channelItemMap(c: ChannelInfoItem): Map<String, Any?>? {
        val id = channelIdOf(c.url)
        if (id.isBlank()) return null
        return mapOf(
            "type" to "channel",
            "id" to id,
            "title" to (c.name ?: ""),
            "description" to (c.description ?: ""),
            "subscriberCount" to c.subscriberCount,
            "thumbnail" to bestImage(c.thumbnails),
        )
    }

    private fun videoInfoMap(info: StreamInfo): Map<String, Any?> = mapOf(
        "type" to "video",
        "id" to info.id,
        "title" to (info.name ?: ""),
        "author" to (info.uploaderName ?: ""),
        "channelId" to channelIdOf(info.uploaderUrl),
        "duration" to info.duration,
        "isLive" to (info.streamType == StreamType.LIVE_STREAM),
        "thumbnail" to bestImage(info.thumbnails),
    )

    // ------------------------------------------------------------------ utils

    private fun watchUrl(id: String) =
        if (id.startsWith("http")) id else "https://www.youtube.com/watch?v=" + id

    private fun playlistUrl(id: String) =
        if (id.startsWith("http")) id else "https://www.youtube.com/playlist?list=" + id

    private fun channelUrl(id: String) =
        if (id.startsWith("http")) id else "https://www.youtube.com/channel/" + id

    /**
     * El id de video de la URL de un resultado. El extractor de NewPipe se
     * apoya en java.net.URL, que en algunas URLs de lista lanza; de ahi el
     * respaldo por regex sobre `v=` / `youtu.be/` antes de descartar el item.
     */
    private fun idOf(url: String?): String? {
        if (url.isNullOrBlank()) return null
        runCatching { yt.streamLHFactory.getId(url) }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?.let { return it }
        return VIDEO_ID_PATTERN.find(url)?.groupValues?.get(1)
    }

    private fun playlistIdOf(url: String?): String? {
        if (url.isNullOrBlank()) return null
        runCatching { yt.playlistLHFactory.getId(url) }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?.let { return it }
        return PLAYLIST_ID_PATTERN.find(url)?.groupValues?.get(1)
    }

    /** `https://www.youtube.com/channel/UCxxxx` -> `UCxxxx`. */
    private fun channelIdOf(url: String?): String {
        val u = url ?: return ""
        val i = u.indexOf("/channel/")
        if (i < 0) return ""
        return u.substring(i + 9).substringBefore('/').substringBefore('?')
    }

    private fun bestImage(images: List<Image>?): String =
        images?.maxByOrNull { it.height }?.url ?: ""

    private val VIDEO_ID_PATTERN =
        Regex("(?:[?&]v=|youtu\\.be/|/shorts/|/embed/|/live/)([A-Za-z0-9_-]{11})")

    private val PLAYLIST_ID_PATTERN = Regex("[?&]list=([A-Za-z0-9_-]+)")

    /**
     * Recorre las paginas de un extractor hasta agotar [maxPages] o juntar
     * [maxItems] elementos, deduplicando por tipo+id. El corte a 40 paginas
     * frena catalogos que nunca dejan de paginar.
     */
    private fun <T : InfoItem> collect(
        firstPage: ListExtractor.InfoItemsPage<T>,
        maxPages: Int,
        maxItems: Int,
        more: (Page) -> ListExtractor.InfoItemsPage<T>,
    ): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        var page: ListExtractor.InfoItemsPage<T>? = firstPage
        var fetched = 0
        while (page != null && out.size < maxItems && fetched < maxPages && fetched < 40) {
            for (item in page.items) {
                if (out.size >= maxItems) break
                val map = infoItemMap(item) ?: continue
                if (!seen.add(map["type"].toString() + "_" + map["id"])) continue
                out.add(map)
            }
            fetched++
            val next = page.nextPage ?: break
            page = runCatching { more(next) }.getOrNull()
        }
        return out
    }
}
