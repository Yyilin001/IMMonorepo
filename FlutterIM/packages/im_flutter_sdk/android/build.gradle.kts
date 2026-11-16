plugins {
    id("com.android.library")
    kotlin("android")
}

android {
    namespace = "com.xmtx.im.flutter"
    compileSdk = 36
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(project(":sharedsdk"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
