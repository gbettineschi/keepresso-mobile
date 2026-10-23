pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "Keespresso"
include(":core")
if (!providers.gradleProperty("coreOnly").isPresent) include(":app")
