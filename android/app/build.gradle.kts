plugins {
    id("com.android.application")
    kotlin("android")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "io.github.gbettineschi.keepressomobile"
    compileSdk = 35
    defaultConfig { applicationId = namespace; minSdk = 28; targetSdk = 35; versionCode = 2; versionName = "0.2.0" }
    buildFeatures { compose = true; buildConfig = true }
    defaultConfig {
        fun field(name: String, property: String) { buildConfigField("String", name, "\"" + providers.gradleProperty(property).orElse("").get().replace("\\", "\\\\").replace("\"", "\\\"") + "\"") }
        field("FIREBASE_APPLICATION_ID", "keespresso.firebase.applicationId")
        field("FIREBASE_API_KEY", "keespresso.firebase.apiKey")
        field("FIREBASE_PROJECT_ID", "keespresso.firebase.projectId")
        field("FIREBASE_SENDER_ID", "keespresso.firebase.senderId")
    }
    val signingInputs = listOf("KEESPRESSO_SIGNING_STORE", "KEESPRESSO_SIGNING_PASSWORD", "KEESPRESSO_SIGNING_ALIAS", "KEESPRESSO_SIGNING_KEY_PASSWORD").associateWith { providers.environmentVariable(it).orNull?.takeIf(String::isNotBlank) }
    require(signingInputs.values.all { it == null } || signingInputs.values.all { it != null }) { "Persistent signing requires all four KEESPRESSO_SIGNING environment variables" }
    if (signingInputs.values.all { it != null }) {
        val persistentDebug = signingConfigs.create("persistentDebug") {
            storeFile = file(signingInputs.getValue("KEESPRESSO_SIGNING_STORE")!!)
            storePassword = signingInputs.getValue("KEESPRESSO_SIGNING_PASSWORD")!!
            keyAlias = signingInputs.getValue("KEESPRESSO_SIGNING_ALIAS")!!
            keyPassword = signingInputs.getValue("KEESPRESSO_SIGNING_KEY_PASSWORD")!!
        }
        buildTypes.getByName("debug").signingConfig = persistentDebug
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation(project(":core"))
    implementation(platform("com.google.firebase:firebase-bom:33.12.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation(platform("androidx.compose:compose-bom:2025.03.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    // Firebase transitively brings Fragment 1.1; Activity Result APIs require at least 1.3.
    implementation("androidx.fragment:fragment:1.8.6")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
