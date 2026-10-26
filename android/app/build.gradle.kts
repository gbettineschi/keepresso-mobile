plugins {
    id("com.android.application")
    kotlin("android")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "io.github.gbettineschi.keepressomobile"
    compileSdk = 35
    defaultConfig {
        applicationId = namespace; minSdk = 28; targetSdk = 35
        versionCode = providers.gradleProperty("keepresso.releaseVersionCode").orElse("5").get().toInt()
        versionName = providers.gradleProperty("keepresso.releaseVersion").orElse("0.4.0").get()
    }
    defaultConfig { testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    buildFeatures { compose = true; buildConfig = true }
    defaultConfig {
        // Preserve existing owners' build configuration across the spelling fix.
        fun field(name: String, property: String) { buildConfigField("String", name, "\"" + providers.gradleProperty(property).orElse(providers.gradleProperty(property.replace("keepresso.", "keespresso."))).orElse("").get().replace("\\", "\\\\").replace("\"", "\\\"") + "\"") }
        field("FIREBASE_APPLICATION_ID", "keepresso.firebase.applicationId")
        field("FIREBASE_API_KEY", "keepresso.firebase.apiKey")
        field("FIREBASE_PROJECT_ID", "keepresso.firebase.projectId")
        field("FIREBASE_SENDER_ID", "keepresso.firebase.senderId")
    }
    val signingInputs = listOf("KEEPRESSO_SIGNING_STORE", "KEEPRESSO_SIGNING_PASSWORD", "KEEPRESSO_SIGNING_ALIAS", "KEEPRESSO_SIGNING_KEY_PASSWORD").associateWith { providers.environmentVariable(it).orElse(providers.environmentVariable(it.replace("KEEPRESSO_", "KEESPRESSO_"))).orNull?.takeIf(String::isNotBlank) }
    require(signingInputs.values.all { it == null } || signingInputs.values.all { it != null }) { "Persistent signing requires all four KEEPRESSO_SIGNING environment variables" }
    if (signingInputs.values.all { it != null }) {
        val persistentDebug = signingConfigs.create("persistentDebug") {
            storeFile = file(signingInputs.getValue("KEEPRESSO_SIGNING_STORE")!!)
            storePassword = signingInputs.getValue("KEEPRESSO_SIGNING_PASSWORD")!!
            keyAlias = signingInputs.getValue("KEEPRESSO_SIGNING_ALIAS")!!
            keyPassword = signingInputs.getValue("KEEPRESSO_SIGNING_KEY_PASSWORD")!!
        }
        buildTypes.getByName("debug").signingConfig = persistentDebug
        buildTypes.getByName("release").signingConfig = persistentDebug
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-intents:3.6.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.03.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
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
