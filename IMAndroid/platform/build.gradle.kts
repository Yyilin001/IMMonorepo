plugins { id("com.android.library"); kotlin("android"); kotlin("plugin.serialization") }
android {
    namespace = "com.xmtx.im.platform"
    compileSdk = 36
    sourceSets.getByName("androidTest").assets.srcDir("../test-fixtures")
    sourceSets.getByName("androidTest").assets.srcDir("../clientkit/src/test/resources")
    sourceSets.getByName("androidTest").java.srcDir("../clientkit/src/testFixtures/kotlin")
    defaultConfig { minSdk = 31; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { jvmToolchain(17) }
dependencies {
    api(project(":clientkit"))
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    api("androidx.camera:camera-view:1.6.2")
    implementation("androidx.exifinterface:exifinterface:1.4.2")
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp:4.12.0")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}
