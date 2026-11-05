plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "fr.nino.watchlink"
    compileSdk = 34

    defaultConfig {
        applicationId = "fr.nino.watchlink"
        // Wear OS 4 (Android 13) minimum : la Galaxy Watch FE est en Wear OS 5
        minSdk = 33
        targetSdk = 34
        versionCode = 13
        versionName = "0.10.0"
    }

    // Clé de signature fixe : Android n'accepte de remplacer l'app par une mise à jour que si elle est signée
    // avec la même clé que la version installée (sinon chaque compilation GitHub aurait sa propre clé).
    signingConfigs {
        getByName("debug") {
            storeFile = file("../debug-signing.jks")
            storePassword = "watchlink"
            keyAlias = "watchlink"
            keyPassword = "watchlink"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
