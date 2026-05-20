plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

fun String.asBuildConfigString(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val imApiBaseUrl = providers.gradleProperty("IM_API_BASE_URL")
    .orElse(providers.environmentVariable("IM_API_BASE_URL"))
    .orElse("http://10.0.2.2:8080")
val imTcpHost = providers.gradleProperty("IM_TCP_HOST")
    .orElse(providers.environmentVariable("IM_TCP_HOST"))
    .orElse("10.0.2.2")
val imTcpPort = providers.gradleProperty("IM_TCP_PORT")
    .orElse(providers.environmentVariable("IM_TCP_PORT"))
    .orElse("9000")
val imTcpRequiresTlsTermination = providers.gradleProperty("IM_TCP_REQUIRES_TLS_TERMINATION")
    .orElse(providers.environmentVariable("IM_TCP_REQUIRES_TLS_TERMINATION"))
    .orElse("false")

android {
    namespace = "com.xmtx.imappandroid"
    compileSdk {
        version = release(36)
    }

    defaultConfig {
        applicationId = "com.xmtx.imappandroid"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "IM_API_BASE_URL", imApiBaseUrl.get().asBuildConfigString())
        buildConfigField("String", "IM_TCP_HOST", imTcpHost.get().asBuildConfigString())
        buildConfigField("int", "IM_TCP_PORT", imTcpPort.get())
        buildConfigField("boolean", "IM_TCP_REQUIRES_TLS_TERMINATION", imTcpRequiresTlsTermination.get())
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":imclientkit"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
