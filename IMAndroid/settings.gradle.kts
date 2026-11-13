pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "IMAndroid"
include(":swiftplatform", ":sharedsdk", ":app")
// Opt-in feasibility harness; it does not add a native runtime to the production App.
if (providers.gradleProperty("enableSwiftProbe").orNull == "true") include(":protocol", ":swiftprobe")
