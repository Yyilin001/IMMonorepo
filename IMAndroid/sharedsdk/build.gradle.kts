plugins { id("com.android.library"); kotlin("android") }
android {
    namespace = "com.xmtx.im.sharedsdk"
    compileSdk = 36
    defaultConfig { minSdk = 31; consumerProguardFiles("consumer-rules.pro"); ndk { abiFilters += "arm64-v8a" } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
// Flutter relocates Gradle outputs. The Swift cross-build has a separate artifact directory.
val nativeLibraries = providers.gradleProperty("imSharedNativeDirectory").map { file(it) }
    .orElse(layout.buildDirectory.dir("native").map { it.asFile })
// Use the common Android source-set API across the native and Flutter Gradle hosts.
extensions.getByType<com.android.build.gradle.BaseExtension>()
    .sourceSets.getByName("main").jniLibs.srcDir(nativeLibraries.get())
kotlin { jvmToolchain(17) }
dependencies {
    api(project(":swiftplatform"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    api("org.jetbrains.kotlinx:kotlinx-collections-immutable:0.4.0")
}
tasks.named("preBuild") {
    doLast { check(nativeLibraries.get().resolve("arm64-v8a/libIMV2SharedSDK.so").isFile) {
        "Build the shared SDK first: python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk"
    } }
}
