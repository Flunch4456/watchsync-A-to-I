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
        versionCode = 1
        versionName = "0.1.0"
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
