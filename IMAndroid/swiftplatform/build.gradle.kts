plugins { id("com.android.library"); kotlin("android") }
android {
    namespace = "com.xmtx.im.swiftplatform"
    compileSdk = 36
    defaultConfig { minSdk = 31; consumerProguardFiles("consumer-rules.pro") }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }

dependencies { implementation("com.squareup.okhttp3:okhttp:4.12.0") }
