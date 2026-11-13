plugins { id("com.android.application"); kotlin("android") }
android {
    namespace = "com.xmtx.im.swiftprobe"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.xmtx.im.swiftprobe"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "phase1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testProguardFiles("test-proguard-rules.pro")
        ndk { abiFilters += "arm64-v8a" }
    }
    sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("native"))
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildTypes {
        // Harness only: allow run-as to export evidence while exercising R8/JNI.
        release { isMinifyEnabled = true; isDebuggable = true; signingConfig = signingConfigs.getByName("debug"); proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") }
    }
    testBuildType = providers.gradleProperty("swiftProbeTestBuildType").orElse("debug").get()
}
kotlin { jvmToolchain(17) }
tasks.named("preBuild") {
    doLast {
        check(layout.buildDirectory.file("native/arm64-v8a/libIMSwiftProbe.so").get().asFile.isFile) {
            "Run python3 experiments/swift-android/build_probe.py from the repository root first"
        }
    }
}
dependencies {
    implementation(project(":swiftplatform"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    androidTestImplementation(project(":protocol"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}
