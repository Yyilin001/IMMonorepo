plugins { id("com.android.library"); kotlin("android") }
android {
    namespace = "com.xmtx.im.sharedsdk"
    compileSdk = 36
    defaultConfig { minSdk = 31; consumerProguardFiles("consumer-rules.pro"); ndk { abiFilters += "arm64-v8a" } }
    sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("native"))
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }
dependencies {
    api(project(":swiftplatform"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    api("org.jetbrains.kotlinx:kotlinx-collections-immutable:0.4.0")
}
tasks.named("preBuild") {
    doLast { check(layout.buildDirectory.file("native/arm64-v8a/libIMV2SharedSDK.so").get().asFile.isFile) {
        "Build the shared SDK first: python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk"
    } }
}
