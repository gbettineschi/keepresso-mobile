plugins { kotlin("jvm") }
kotlin { jvmToolchain(17) }
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
    testImplementation(kotlin("test-junit"))
}
tasks.test {
    systemProperty("vectors", rootProject.file("../shared/vectors.json").absolutePath)
    systemProperty("relayVectors", rootProject.file("../shared/relay-vectors.json").absolutePath)
}
