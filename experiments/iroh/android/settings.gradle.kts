pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "KeepressoIrohTrial"
include(":probe", ":core")
project(":core").projectDir = file("../../../android/core")
