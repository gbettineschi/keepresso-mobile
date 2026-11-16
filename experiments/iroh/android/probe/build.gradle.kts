plugins { id("com.android.application"); kotlin("android") }
android {
    namespace = "io.github.gbettineschi.keepressomobile.irohtrial"
    compileSdk = 35
    defaultConfig {
        applicationId = namespace
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "trial"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    // The shared JVM JAR also carries desktop binaries. Android loads the AAR's
    // lib/<ABI> libraries; including desktop resources only inflates the APK.
    packaging.resources.excludes += setOf("darwin-*/**", "win32-*/**", "linux-*/**")
}
dependencies {
    implementation(project(":core"))
    implementation("computer.iroh:iroh-android:1.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
