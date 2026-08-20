# Keep Flutter internal utility classes accessed via JNI by path_provider_android
-keep class io.flutter.util.** { *; }

# NewPipeExtractor arrastra Rhino (org.mozilla.javascript) para resolver el JS
# del reproductor de YouTube. Rhino referencia APIs que solo existen en la JVM
# de escritorio (java.beans, javax.script, el enlazador jdk.dynalink de su
# optimizador); en Android tira del camino interpretado y nunca las toca.
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn jdk.dynalink.**

# Rhino resuelve por reflexion los puentes JS <-> Java, asi que R8 no puede
# renombrar sus clases sin romper la extraccion de streams en runtime.
-keep class org.mozilla.javascript.** { *; }

# NewPipeExtractor usa protobuf-javalite para los tokens de continuacion de las
# LISTAS (YoutubePlaylistExtractor -> PlaylistProtobufContinuation). Las clases
# generadas de protobuf se construyen por reflexion sobre sus propios campos,
# asi que si R8 los renombra la lista se extrae vacia -- y solo la lista: ni la
# busqueda ni los streams pasan por aqui, que es justo el sintoma que daba.
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
    <methods>;
}
-dontwarn com.google.protobuf.**

# Por el mismo motivo, sin depender de que R8 acierte con lo que es alcanzable.
-keep class org.schabi.newpipe.extractor.services.youtube.protos.** { *; }
