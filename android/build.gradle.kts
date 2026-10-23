// Keep Android's plugin in the same parent classloader as Kotlin. Core-only builds
// deliberately do not resolve or apply AGP and need no Android SDK.
buildscript {
    repositories { google(); mavenCentral() }
    dependencies {
        if (!project.providers.gradleProperty("coreOnly").isPresent) {
            classpath("com.android.tools.build:gradle:8.9.2")
        }
    }
}
plugins {
    kotlin("jvm") version "2.1.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.20" apply false
}
