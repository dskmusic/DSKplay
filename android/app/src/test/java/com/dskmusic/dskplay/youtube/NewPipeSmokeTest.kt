package com.dskmusic.dskplay.youtube

import org.junit.BeforeClass
import org.junit.Test

/**
 * Ejecuta [NewPipeExtraction] —el mismo codigo que corre en el movil— contra
 * YouTube de verdad. Sirve para saber si un fallo esta en NewPipeExtractor o en
 * el pegamento Dart, sin instalar el APK, y para que subir la version de
 * NewPipeExtractor falle aqui en vez de en el telefono del usuario.
 *
 *     cd android
 *     JAVA_HOME=<jbr de Android Studio> ./gradlew :app:testReleaseUnitTest \
 *         --tests "*NewPipeSmokeTest*"
 */
class NewPipeSmokeTest {

    companion object {
        private const val PLAYLIST_ID = "PLgzTt0k8mXzEk586ze4BjvDXR7c-TUSnx"
        private const val VIDEO_ID = "dQw4w9WgXcQ"

        @BeforeClass
        @JvmStatic
        fun setUp() = NewPipeExtraction.init()
    }

    private fun show(label: String, items: List<Map<String, Any?>>) {
        println("$label: ${items.size}")
        for (m in items.take(3)) println("  $m")
    }

    @Test
    fun searchVideos() {
        val items = NewPipeExtraction.search("coldplay yellow", listOf("videos"), 1)
        show("videos", items)
        check(items.isNotEmpty()) { "busqueda de videos vacia" }
        check(items.all { it["type"] == "video" }) { "tipos raros en videos" }
        check(items.all { (it["id"] as String).isNotBlank() }) { "algun video sin id" }
    }

    @Test
    fun searchPlaylists() {
        val items = NewPipeExtraction.search("coldplay album", listOf("playlists"), 1)
        show("listas", items)
        check(items.isNotEmpty()) { "busqueda de listas vacia" }
        check(items.all { it["type"] == "playlist" }) { "tipos raros en listas" }
        check(items.all { (it["id"] as String).isNotBlank() }) { "alguna lista sin id" }
    }

    @Test
    fun searchArtists() {
        val items = NewPipeExtraction.search("coldplay", listOf("channels"), 1)
        show("canales", items)
        check(items.isNotEmpty()) { "busqueda de canales vacia" }
    }

    @Test
    fun playlistMeta() {
        val info = NewPipeExtraction.playlist(PLAYLIST_ID)
        println("lista: $info")
        check((info["title"] as String).isNotBlank()) { "la lista no tiene titulo" }
    }

    @Test
    fun playlistItems() {
        val items = NewPipeExtraction.playlistItems(PLAYLIST_ID, 500)
        show("canciones de la lista", items)
        check(items.isNotEmpty()) { "la lista vino vacia" }
        check(items.all { (it["id"] as String).isNotBlank() }) { "alguna cancion sin id" }
    }

    @Test
    fun streams() {
        val info = NewPipeExtraction.streams(VIDEO_ID)
        @Suppress("UNCHECKED_CAST")
        val audio = info["audio"] as List<Map<String, Any?>>
        println("video: ${info["title"]} | ${info["author"]} | ${info["duration"]}s")
        show("audio", audio)
        check(audio.isNotEmpty()) { "sin streams de audio reproducibles" }
    }

    @Test
    fun related() {
        val items = NewPipeExtraction.related(VIDEO_ID)
        show("relacionados", items)
        check(items.isNotEmpty()) { "sin relacionados" }
    }

    @Test
    fun channel() {
        val info = NewPipeExtraction.channel("UCIaFw5VBEK8qaW6nRpx_qnw")
        println("canal: $info")
        check((info["title"] as String).isNotBlank()) { "el canal no tiene titulo" }
    }

    /**
     * Lo que hace la pantalla de busqueda: tres extracciones a la vez. Si
     * NewPipeExtractor no aguanta la concurrencia, aqui se ve.
     */
    @Test
    fun concurrentSearches() {
        val pool = java.util.concurrent.Executors.newFixedThreadPool(4)
        val tasks = listOf(
            java.util.concurrent.Callable { NewPipeExtraction.search("coldplay yellow", listOf("videos"), 5) },
            java.util.concurrent.Callable { NewPipeExtraction.search("coldplay album", listOf("playlists"), 1) },
            java.util.concurrent.Callable { NewPipeExtraction.search("coldplay", listOf("playlists"), 1) },
            java.util.concurrent.Callable { NewPipeExtraction.playlistItems(PLAYLIST_ID, 500) },
        )
        val results = pool.invokeAll(tasks)
        pool.shutdown()

        var fallos = 0
        for ((i, f) in results.withIndex()) {
            try {
                val items = f.get()
                println("tarea $i -> ${items.size} elementos")
                if (items.isEmpty()) fallos++
            } catch (e: Exception) {
                println("tarea $i -> EXCEPCION ${e.cause ?: e}")
                fallos++
            }
        }
        check(fallos == 0) { "$fallos de ${tasks.size} tareas concurrentes fallaron" }
    }

    @Test
    fun suggestions() {
        val list = NewPipeExtraction.suggestions("coldpl")
        println("sugerencias: $list")
        check(list.isNotEmpty()) { "sin sugerencias" }
    }
}
