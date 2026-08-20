import java.util.Properties
import java.io.FileInputStream

// Version de NewPipeExtractor. La actualiza sola el workflow
// .github/workflows/newpipe_sync.yml; no cambiar el formato de esta linea.
val newpipeVersion = "v0.26.5"

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.reader(Charsets.UTF_8).use { reader ->
        localProperties.load(reader)
    }
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { inputStream ->
        keystoreProperties.load(inputStream)
    }
}

android {
    namespace = "com.dskmusic.dskplay"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Kept after dropping flutter_local_notifications: other plugins
        // (and the AGP/Flutter toolchain itself) still expect it, and
        // turning it off buys nothing.
        isCoreLibraryDesugaringEnabled = true
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        applicationId = "com.dskmusic.dskplay"
        // 26 y no 24: NewPipeExtractor usa java.util.Base64 (API 26) al
        // extraer LISTAS, asi que en Android 7 abrir una lista petaria.
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // From decoded key
            storeFile = file("key.jks")

            // From key.properties
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildFeatures {
        buildConfig = true
    }

    dependenciesInfo {
        // Disables dependency metadata when building APKs.
        includeInApk = false
        // Disables dependency metadata when building Android App Bundles.
        includeInBundle = false
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = " DEBUG"
        }
    }
}

// x86_64 solo lo usan los emuladores: en el APK universal eran ~76 MB de
// librerias nativas que ningun movil llega a abrir (122 MB -> 89 MB). Va aqui
// y no en `ndk { abiFilters }` porque el plugin de Flutter decide los ABIs por
// su cuenta y pisa esa opcion; y solo en release, para que el debug siga
// instalando en emulador.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.add("**/x86_64/**")
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Extraccion de YouTube en el dispositivo (busqueda, streams, listas,
    // canales) - sustituye a youtube_explode_dart.
    implementation("com.github.TeamNewPipe:NewPipeExtractor:$newpipeVersion")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Sonda de extraccion contra YouTube de verdad (NewPipeSmokeTest).
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

afterEvaluate {
    apply(from = "../no-build-id.gradle")
}
