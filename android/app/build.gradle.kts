import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// google-services.json comes from your Firebase project (git-ignored). Without it the app
// builds and runs, but has no FCM token and can't receive.
if (file("google-services.json").exists()) apply(plugin = "com.google.gms.google-services")

// Relay config lives in android/teleport.properties (git-ignored); see teleport.properties.example.
val teleport = Properties().apply {
    rootProject.file("teleport.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
    namespace = "app.teleport.android"
    compileSdk = 37

    defaultConfig {
        applicationId = teleport.getProperty("applicationId", "com.peteranyaogu.teleport")
        minSdk = 31 // Keystore ECDH (PURPOSE_AGREE_KEY)
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "RELAY_URL", "\"${teleport.getProperty("relayUrl", "")}\"")
        buildConfigField("String", "RELAY_KEY", "\"${teleport.getProperty("relayKey", "")}\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":core"))

    implementation(platform("com.google.firebase:firebase-bom:35.2.0"))
    implementation("com.google.firebase:firebase-messaging")

    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.material3:material3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    implementation("com.google.zxing:core:3.5.4")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
