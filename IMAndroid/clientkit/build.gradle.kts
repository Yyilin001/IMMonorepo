plugins { kotlin("jvm"); kotlin("plugin.serialization"); `java-library` }
kotlin { jvmToolchain(17) }
kotlin.sourceSets.getByName("test").kotlin.srcDir("src/testFixtures/kotlin")
dependencies {
    api(project(":protocol"))
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    api("org.jetbrains.kotlinx:kotlinx-collections-immutable:0.4.0")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.zxing:core:3.5.4")
    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}
tasks.test { dependsOn(rootProject.tasks.named("verifyProtocolVersion")) }
