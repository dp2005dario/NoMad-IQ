import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Llave de subida a Google Play ("upload key"). Sus datos van en
// android/key.properties, que NUNCA se sube a git (está en .gitignore).
// Cómo crearla: docs/guia-play-store.md. Si el archivo no existe (por
// ejemplo en el CI o en tu PC antes de crearla), la versión "release" se
// firma con la llave de pruebas: sirve para probar, pero Play la rechaza.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasUploadKey = keyProps.getProperty("storeFile") != null

android {
    namespace = "com.nomadiq.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // "Desugaring": deja usar funciones modernas de Java (fechas...) en
        // móviles Android antiguos. Lo exige flutter_local_notifications.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Identificador único en Google Play. Una vez publicada la app NO se
        // puede cambiar nunca (sería otra app distinta).
        applicationId = "com.nomadiq.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Salen de "version: 1.0.0+1" en pubspec.yaml: lo de antes del "+" es
        // lo que ve el usuario y el número de después debe SUBIR en cada
        // versión que mandes a Play.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("upload")
            } else {
                logger.warn("NomadIQ: falta android/key.properties; release firmada con la llave de PRUEBAS (Play la rechazará).")
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // La biblioteca que hace posible el "desugaring" de arriba.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Lector de tickets (ML Kit): el alfabeto latino ya viene con el plugin.
    // Estos añaden los tickets en chino, japonés, coreano e hindi/devanagari
    // (Tokio, Seúl, Delhi... son destinos de viaje muy comunes). Cada uno
    // pesa unos MB, pero Play solo descarga lo de tu tipo de móvil.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    // La ventana de la huella (local_auth) necesita temas "AppCompat" para no
    // fallar en Android 8 y anteriores (ver res/values/styles.xml).
    implementation("androidx.appcompat:appcompat:1.7.0")
}
